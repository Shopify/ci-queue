require 'redis'

module CI
  module Queue
    module Redis
      def self.new(*args)
        Worker.new(*args)
      end

      Error = Class.new(StandardError)
      LostMaster = Class.new(Error)

      class Base
        def initialize(redis:, build_id:)
          @redis = redis
          @key = "build:#{build_id}"
        end

        def empty?
          size == 0
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
          end.flatten.reverse
        end

        def progress
          total - size
        end

        def wait_for_master(timeout: 10)
          return true if master?
          (timeout * 10).times do
            case master_status
            when 'ready', 'finished'
              return true
            else
              sleep 0.1
            end
          end
          raise LostMaster, "The master worker is still `#{master_status}` after 10 seconds waiting."
        end

        private

        attr_reader :redis

        def key(*args)
          [@key, *args].join(':')
        end

        def master_status
          redis.get(key('master-status'))
        end

        def eval_script(script, *args)
          @scripts_cache ||= {}
          sha = (@scripts_cache[script] ||= redis.script(:load, script))
          redis.evalsha(sha, *args)
        end
      end

      class Supervisor < Base
        def master?
          false
        end

        def wait_for_workers
          return false unless wait_for_master

          sleep 0.1 until empty?
          true
        end
      end

      class Worker < Base
        attr_reader :total

        def initialize(tests, redis:, build_id:, worker_id:, timeout:)
          @shutdown_required = false
          super(redis: redis, build_id: build_id)
          @worker_id = worker_id
          @timeout = timeout
          push(tests)
        end

        def shutdown!
          @shutdown_required = true
        end

        def shutdown_required?
          @shutdown_required
        end

        def master?
          @master
        end

        def poll
          wait_for_master
          while test = reserve
            yield test
            acknowledge(test)
          end
        end

        def processed
          redis.lrange(key("worker:#{worker_id}:queue"), 0, -1)
        end

        private

        attr_reader :worker_id, :timeout

        RESERVE_TEST = %{
          local queue_key = KEYS[1]
          local zset_key = KEYS[2]
          local current_time = ARGV[1]

          local test = redis.call('rpop', queue_key)
          if test then
            redis.call('zadd', zset_key, current_time, test)
            return test
          else
            return nil
          end
        }
        def reserve
          return if shutdown_required?

          if test = eval_script(RESERVE_TEST, keys: [key('queue'), key('running')], argv: [Time.now.to_f])
            return test
          else
            reserve_lost_test
          end
        end

        RESERVE_LOST_TEST = %{
          local zset_key = KEYS[1]
          local current_time = ARGV[1]
          local timeout = ARGV[2]

          local test = redis.call('zrangebyscore', zset_key, 0, current_time - timeout)[1]
          if test then
            redis.call('zadd', zset_key, current_time, test)
            return test
          else
            return nil
          end
        }
        def reserve_lost_test
          until redis.zcard(key('running')) == 0
            if test = eval_script(RESERVE_LOST_TEST, keys: [key('running')], argv: [Time.now.to_f, timeout])
              return test
            end
            sleep 0.1
          end
          nil
        end

        ACKNOWLEDGE = %{
          local zset_key = KEYS[1]
          local processed_count_key = KEYS[2]
          local test = ARGV[1]

          if redis.call('zrem', zset_key, test) == 1 then
            redis.call('incr', processed_count_key)
          end
        }
        def acknowledge(test)
          eval_script(ACKNOWLEDGE, keys: [key('running'), key('processed')], argv: [test])
          redis.lpush(key("worker:#{worker_id}:queue"), test)
        end

        def push(tests)
          @total = tests.size
          if @master = redis.setnx(key('master-status'), 'setup')
            redis.multi do
              redis.lpush(key('queue'), tests)
              redis.set(key('total'), @total)
              redis.set(key('master-status'), 'ready')
            end
          end
        end
      end
    end
  end
end
