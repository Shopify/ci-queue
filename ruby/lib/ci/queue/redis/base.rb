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
            result = super
            logger = redis_config.custom[:debug_log]
            logger.info("#{command}: #{result}")
            result
          end

          def call_pipelined(commands, redis_config)
            result = super
            logger = redis_config.custom[:debug_log]
            logger.info("#{commands}: #{result}")
            result
          end
        end

        def initialize(redis_url, config)
          @redis_url = redis_url
          @config = config
          if ::Redis::VERSION > "5.0.0"
            @redis = ::Redis.new(
              url: redis_url,
              # Booting a CI worker is costly, so in case of a Redis blip,
              # it makes sense to retry for a while before giving up.
              reconnect_attempts: [0, 0, 0.1, 0.5, 1, 3, 5],
              middlewares: custom_middlewares,
              custom: custom_config,
            )
          else
            @redis = ::Redis.new(url: redis_url)
          end
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
      end
    end
  end
end
