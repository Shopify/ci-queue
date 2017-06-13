require 'ci/queue/static'

module CI
  module Queue
    module Redis
      ReservationError = Class.new(StandardError)

      class << self
        attr_accessor :requeue_offset
      end
      self.requeue_offset = 42

      class Worker < Base
        attr_reader :total

        def initialize(tests, redis:, build_id:, worker_id:, timeout:, max_requeues: 0, requeue_tolerance: 0.0)
          @reserved_test = nil
          @max_requeues = max_requeues
          @global_max_requeues = (tests.size * requeue_tolerance).ceil
          @shutdown_required = false
          super(redis: redis, build_id: build_id)
          @worker_id = worker_id.to_s
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
          until shutdown_required? || empty?
            if test = reserve
              yield test
            else
              sleep 0.05
            end
          end
        rescue ::Redis::BaseConnectionError
        end

        def retry_queue(**args)
          Retry.new(
            redis.lrange(key('worker', worker_id, 'queue'), 0, -1).reverse.uniq,
            redis: redis,
            build_id: build_id,
            worker_id: worker_id,
            **args
          )
        end

        def minitest_reporters
          require 'minitest/reporters/redis_reporter'
          @minitest_reporters ||= [
            Minitest::Reporters::RedisReporter::Worker.new(
              redis: redis,
              build_id: build_id,
              worker_id: worker_id,
            )
          ]
        end


        ACKNOWLEDGE = %{
          local zset_key = KEYS[1]
          local processed_key = KEYS[2]

          local worker_id = ARGV[1]
          local test = ARGV[2]

          redis.call('zrem', zset_key, test)
          return redis.call('sadd', processed_key, test)
        }
        def acknowledge(test)
          raise_on_mismatching_test(test)
          eval_script(
            ACKNOWLEDGE,
            keys: [key('running'), key('processed')],
            argv: [worker_id, test],
          ) == 1
        end

        REQUEUE = %{
          local processed_key = KEYS[1]
          local requeues_count_key = KEYS[2]
          local queue_key = KEYS[3]
          local zset_key = KEYS[4]

          local max_requeues = tonumber(ARGV[1])
          local global_max_requeues = tonumber(ARGV[2])
          local test = ARGV[3]
          local offset = ARGV[4]

          if redis.call('sismember', processed_key, test) == 1 then
            return false
          end

          local global_requeues = tonumber(redis.call('hget', requeues_count_key, '___total___'))
          if global_requeues and global_requeues >= tonumber(global_max_requeues) then
            return false
          end

          local requeues = tonumber(redis.call('hget', requeues_count_key, test))
          if requeues and requeues >= max_requeues then
            return false
          end

          redis.call('hincrby', requeues_count_key, '___total___', 1)
          redis.call('hincrby', requeues_count_key, test, 1)

          local pivot = redis.call('lrange', queue_key, -1 - offset, 0 - offset)[1]
          if pivot then
            redis.call('linsert', queue_key, 'BEFORE', pivot, test)
          else
            redis.call('lpush', queue_key, test)
          end

          redis.call('zrem', zset_key, test)

          return true
        }
        def requeue(test, offset: Redis.requeue_offset)
          raise_on_mismatching_test(test)

          requeued = eval_script(
            REQUEUE,
            keys: [key('processed'), key('requeues-count'), key('queue'), key('running')],
            argv: [max_requeues, global_max_requeues, test, offset],
          ) == 1

          @reserved_test = test unless requeued
          requeued
        end

        private

        attr_reader :worker_id, :timeout, :max_requeues, :global_max_requeues

        def raise_on_mismatching_test(test)
          if @reserved_test == test
            @reserved_test = nil
          else
            raise ReservationError, "Acknowledged #{test.inspect} but #{@reserved_test.inspect} was reserved"
          end
        end

        def reserve
          if @reserved_test
            raise ReservationError, "#{@reserved_test.inspect} is already reserved. " \
              "You have to acknowledge it before you can reserve another one"
          end

          @reserved_test = (try_to_reserve_lost_test || try_to_reserve_test)
        end

        RESERVE_TEST = %{
          local queue_key = KEYS[1]
          local zset_key = KEYS[2]
          local processed_key = KEYS[3]
          local worker_queue_key = KEYS[4]

          local current_time = ARGV[1]

          local test = redis.call('rpop', queue_key)
          if test then
            redis.call('zadd', zset_key, current_time, test)
            redis.call('lpush', worker_queue_key, test)
            return test
          else
            return nil
          end
        }

        def try_to_reserve_test
          eval_script(
            RESERVE_TEST,
            keys: [key('queue'), key('running'), key('processed'), key('worker', worker_id, 'queue')],
            argv: [Time.now.to_f],
          )
        end

        RESERVE_LOST_TEST = %{
          local zset_key = KEYS[1]
          local processed_key = KEYS[2]
          local worker_queue_key = KEYS[3]

          local current_time = ARGV[1]
          local timeout = ARGV[2]

          local lost_tests = redis.call('zrangebyscore', zset_key, 0, current_time - timeout)
          for _, test in ipairs(lost_tests) do
            if redis.call('sismember', processed_key, test) == 0 then
              redis.call('zadd', zset_key, current_time, test)
              redis.call('lpush', worker_queue_key, test)
              return test
            end
          end

          return nil
        }
        def try_to_reserve_lost_test
          eval_script(
            RESERVE_LOST_TEST,
            keys: [key('running'), key('completed'), key('worker', worker_id, 'queue')],
            argv: [Time.now.to_f, timeout],
          )
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
          register
        rescue ::Redis::BaseConnectionError
          raise if @master
        end

        def register
          redis.sadd(key('workers'), worker_id)
        end
      end
    end
  end
end
