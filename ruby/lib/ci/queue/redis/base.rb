# frozen_string_literal: true
module CI
  module Queue
    module Redis
      class Base
        include Common

        TEN_MINUTES = 60 * 10
        CONNECTION_ERRORS = [
          ::Redis::BaseConnectionError,
          ::SocketError, # https://github.com/redis/redis-rb/pull/631
        ].freeze

        module RedisInstrumentation
          def call(command, redis_config)
            logger = redis_config.custom[:debug_log]
            logger.info("Running '#{command}'")
            result = super
            logger.info("Finished '#{command}': #{result}")
            result
          end

          def call_pipelined(commands, redis_config)
            logger = redis_config.custom[:debug_log]
            logger.info("Running '#{commands}'")
            result = super
            logger.info("Finished '#{commands}': #{result}")
            result
          end
        end

        def initialize(redis_url, config)
          @redis_url = redis_url
          @config = config
          if ::Redis::VERSION > "5.0.0"
            connection_options = {
              url: redis_url,
              # Booting a CI worker is costly, so in case of a Redis blip,
              # it makes sense to retry for a while before giving up.
              reconnect_attempts: reconnect_attempts,
              middlewares: custom_middlewares,
              custom: custom_config,
            }

            if !config.strict_ssl
              connection_options[:ssl_params] = { verify_mode: OpenSSL::SSL::VERIFY_NONE }
            end

            @redis = ::Redis.new(**connection_options)
          else
            @redis = ::Redis.new(url: redis_url)
          end
        end

        def reconnect_attempts
          return [] if ENV["CI_QUEUE_DISABLE_RECONNECT_ATTEMPTS"]

          [0, 0, 0.1, 0.5, 1, 3, 5]
        end

        def with_heartbeat(id)
          if heartbeat_enabled?
            ensure_heartbeat_thread_alive!
            heartbeat_state.set(:tick, id)
          end

          yield
        ensure
          heartbeat_state.set(:reset) if heartbeat_enabled?
        end

        def ensure_heartbeat_thread_alive!
          return unless heartbeat_enabled?
          return if @heartbeat_thread&.alive?

          @heartbeat_thread = Thread.start { heartbeat }
        end

        def boot_heartbeat_process!
          return unless heartbeat_enabled?

          heartbeat_process.boot!
        end

        def stop_heartbeat!
          return unless heartbeat_enabled?

          heartbeat_state.set(:stop)
          heartbeat_process.shutdown!
        end

        def custom_config
          return unless config.debug_log

          require 'logger'
          { debug_log: Logger.new(config.debug_log) }
        end

        def custom_middlewares
          return unless config.debug_log

          [RedisInstrumentation]
        end

        def exhausted?
          queue_initialized? && size == 0
        end

        def expired?
          if (created_at = redis.get(key('created-at')))
            (created_at.to_f + config.redis_ttl + TEN_MINUTES) < CI::Queue.time_now.to_f
          else
            # if there is no created at set anymore we assume queue is expired
            true
          end
        end

        def created_at=(timestamp)
          redis.setnx(key('created-at'), timestamp)
        end

        def size
          redis.multi do |transaction|
            transaction.llen(key('queue'))
            transaction.zcard(key('running'))
          end.inject(:+)
        end

        def remaining
          redis.llen(key('queue'))
        end

        def running
          redis.zcard(key('running'))
        end

        def to_a
          redis.multi do |transaction|
            transaction.lrange(key('queue'), 0, -1)
            transaction.zrange(key('running'), 0, -1)
          end.flatten.reverse.map { |k| index.fetch(k) }
        end

        def progress
          total - size
        end

        def wait_for_master(timeout: 30)
          return true if master?
          return true if queue_initialized?

          (timeout * 10 + 1).to_i.times do
            if queue_initialized?
              return true
            else
              sleep 0.1
            end
          end

          raise LostMaster, "The master worker is still `#{master_status}` after #{timeout} seconds waiting."
        end

        def workers_count
          redis.scard(key('workers'))
        end

        def queue_initialized?
          @queue_initialized ||= begin
            status = master_status
            status == 'ready' || status == 'finished'
          end
        end

        def queue_initializing?
          master_status == 'setup'
        end

        def increment_test_failed
          redis.incr(key('test_failed_count'))
        end

        def test_failed
          redis.get(key('test_failed_count')).to_i
        end

        def max_test_failed?
          return false if config.max_test_failed.nil?

          test_failed >= config.max_test_failed
        end

        private

        attr_reader :redis, :redis_url

        def with_redis_timeout(timeout)
          prev = redis._client.timeout
          redis._client.timeout = timeout
          yield
        ensure
          redis._client.timeout = prev
        end

        def measure
          starting = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          yield
          Process.clock_gettime(Process::CLOCK_MONOTONIC) - starting
        end

        def key(*args)
          ['build', build_id, *args].join(':')
        end

        def build_id
          config.build_id
        end

        def master_status
          redis.get(key('master-status'))
        end

        def eval_script(script, *args)
          redis.evalsha(load_script(script), *args)
        end

        def load_script(script)
          @scripts_cache ||= {}
          @scripts_cache[script] ||= redis.script(:load, read_script(script))
        end

        def read_script(name)
          ::File.read(::File.join(CI::Queue::DEV_SCRIPTS_ROOT, "#{name}.lua"))
        rescue SystemCallError
          ::File.read(::File.join(CI::Queue::RELEASE_SCRIPTS_ROOT, "#{name}.lua"))
        end

        class HeartbeatProcess
          def initialize(redis_url, zset_key, processed_key, owners_key, worker_queue_key)
            @redis_url = redis_url
            @zset_key = zset_key
            @processed_key = processed_key
            @owners_key = owners_key
            @worker_queue_key = worker_queue_key
          end

          def boot!
            child_read, @pipe = IO.pipe
            ready_pipe, child_write = IO.pipe
            @pipe.binmode
            @pid = Process.spawn(
              RbConfig.ruby,
              ::File.join(__dir__, "monitor.rb"),
              @redis_url,
              @zset_key,
              @processed_key,
              @owners_key,
              @worker_queue_key,
              in: child_read,
              out: child_write,
            )
            child_read.close
            child_write.close

            # Check the process is alive.
            if ready_pipe.wait_readable(10)
              ready_pipe.gets
              ready_pipe.close
              Process.kill(0, @pid)
            else
              Process.kill(0, @pid)
              Process.wait(@pid)
              raise "Monitor child wasn't ready after 10 seconds"
            end
            @pipe
          end

          def shutdown!
            @pipe.close
            begin
              _, status = Process.waitpid2(@pid)
              status
            rescue Errno::ECHILD
              nil
            end
          end

          def tick!(id)
            send_message(:tick!, id: id)
          end

          private

          def send_message(*message)
            payload = message.to_json
            @pipe.write([payload.bytesize].pack("L").b, payload)
          end
        end

        class State
          def initialize
            @state = nil
            @mutex = Mutex.new
            @cond = ConditionVariable.new
          end

          def set(*state)
            @state = state
            @mutex.synchronize do
              @cond.broadcast
            end
          end

          def wait(timeout)
            @mutex.synchronize do
              @cond.wait(@mutex, timeout)
            end
            @state
          end
        end

        def heartbeat_state
          @heartbeat_state ||= State.new
        end

        def heartbeat_process
          @heartbeat_process ||= HeartbeatProcess.new(
            @redis_url,
            key('running'),
            key('processed'),
            key('owners'),
            key('worker', worker_id, 'queue'),
          )
        end

        def heartbeat_enabled?
          config.max_missed_heartbeat_seconds
        end

        def heartbeat
          Thread.current.name = "CI::Queue#heartbeat"
          Thread.current.abort_on_exception = true

          timeout = config.timeout.to_i
          loop do
            command = nil
            command = heartbeat_state.wait(1) # waits for max 1 second but wakes up immediately if we receive a command

            case command&.first
            when :tick
              if timeout > 0
                heartbeat_process.tick!(command.last)
                timeout -= 1
              end
            when :reset
              timeout = config.timeout.to_i
            when :stop
              break
            end
          end
        end
      end
    end
  end
end
