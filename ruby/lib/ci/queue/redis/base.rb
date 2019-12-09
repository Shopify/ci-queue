# frozen_string_literal: true
module CI
  module Queue
    module Redis
      class Base
        include Common

        CONNECTION_ERRORS = [
          ::Redis::BaseConnectionError,
          ::SocketError, # https://github.com/redis/redis-rb/pull/631
        ].freeze

        def initialize(redis_url, config)
          @redis_url = redis_url
          @redis = ::Redis.new(url: redis_url)
          @config = config
        end

        def exhausted?
          queue_initialized? && size == 0
        end

        def size
          redis.multi do
            redis.llen(key('queue'))
            redis.zcard(key('running'))
          end.inject(:+)
        end

        def to_a
          redis.multi do
            redis.lrange(key('queue'), 0, -1)
            redis.zrange(key('running'), 0, -1)
          end.flatten.reverse.map { |k| index.fetch(k) }
        end

        def progress
          total - size
        end

        def wait_for_master(timeout: 10)
          return true if master?
          (timeout * 10 + 1).to_i.times do
            if queue_initialized?
              return true
            else
              sleep 0.1
            end
          end
          raise LostMaster, "The master worker is still `#{master_status}` after 10 seconds waiting."
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
