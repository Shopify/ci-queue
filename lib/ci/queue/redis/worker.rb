require 'ci/queue/static'

module CI
  module Queue
    module Redis
      ReservationError = Class.new(StandardError)

      class Worker < Base
        attr_reader :total

        def initialize(tests, redis:, build_id:, worker_id:, timeout:, max_requeues: 0, requeue_tolerance: 0.0)
          @reserved_test = nil
          @max_requeues = max_requeues
          @global_max_requeues = (tests.size * requeue_tolerance).ceil
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
          until shutdown_required? || empty?
            if test = reserve
              yield test
            else
              sleep 0.05
            end
          end
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

        def acknowledge(test, success)
          if @reserved_test == test
            @reserved_test = nil
          else
            raise ReservationError, "Acknowledged #{test.inspect} but #{@reserved_test.inspect} was reserved"
          end

          if !success && should_requeue?(test)
            requeue(test)
            false
          else
            ack(test)
            true
          end
        end

        private

        attr_reader :worker_id, :timeout, :max_requeues, :global_max_requeues

        def should_requeue?(test)
          individual_requeues, global_requeues = redis.multi do
            redis.hincrby(key('requeues-count'), test, 1)
            redis.hincrby(key('requeues-count'), '___total___'.freeze, 1)
          end

          if individual_requeues.to_i > max_requeues || global_requeues.to_i > global_max_requeues
            redis.multi do
              redis.hincrby(key('requeues-count'), test, -1)
              redis.hincrby(key('requeues-count'), '___total___'.freeze, -1)
            end
            return false
          end

          true
        end

        def requeue(test)
          load_script(ACKNOWLEDGE)
          redis.multi do
            redis.decr(key('processed'))
            redis.rpush(key('queue'), test)
            ack(test)
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
          local current_time = ARGV[1]

          local test = redis.call('rpop', queue_key)
          if test then
            redis.call('zadd', zset_key, current_time, test)
            return test
          else
            return nil
          end
        }
        def try_to_reserve_test
          eval_script(RESERVE_TEST, keys: [key('queue'), key('running')], argv: [Time.now.to_f])
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
        def try_to_reserve_lost_test
          eval_script(RESERVE_LOST_TEST, keys: [key('running')], argv: [Time.now.to_f, timeout])
        end

        ACKNOWLEDGE = %{
          local zset_key = KEYS[1]
          local processed_count_key = KEYS[2]
          local test = ARGV[1]

          if redis.call('zrem', zset_key, test) == 1 then
            redis.call('incr', processed_count_key)
          end
        }
        def ack(test)
          eval_script(ACKNOWLEDGE, keys: [key('running'), key('processed')], argv: [test])
          redis.lpush(key('worker', worker_id, 'queue'), test)
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
