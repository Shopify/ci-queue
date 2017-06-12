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

        def acknowledge(test)
          raise_on_mismatching_test(test)
          ack(test)
        end

        REQUEUE = %{
          local queue_key = KEYS[1]
          local test = ARGV[1]
          local offset = ARGV[2]

          local pivot = redis.call('lrange', queue_key, -1 - offset, 0 - offset)[1]
          if pivot then
            redis.call('linsert', queue_key, 'BEFORE', pivot, test)
          else
            redis.call('lpush', queue_key, test)
          end
        }
        def requeue(test, offset: Redis.requeue_offset)
          return false unless should_requeue?(test) # TODO(byroot): inline `should_requeue?` to avoid race condition

          raise_on_mismatching_test(test)

          load_script(ACKNOWLEDGE)
          load_script(REQUEUE)
          redis.multi do
            redis.decr(key('processed'))
            eval_script(REQUEUE, keys: [key('queue')], argv: [test, offset])
            ack(test)
          end
          true
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

        def should_requeue?(test)
          individual_requeues, global_requeues, owner = redis.multi do
            redis.hincrby(key('requeues-count'), test, 1)
            redis.hincrby(key('requeues-count'), '___total___'.freeze, 1)
            redis.hget(key('owners'), test)
          end

          if owner != worker_id || individual_requeues.to_i > max_requeues || global_requeues.to_i > global_max_requeues
            redis.multi do
              redis.hincrby(key('requeues-count'), test, -1)
              redis.hincrby(key('requeues-count'), '___total___'.freeze, -1)
            end
            return false
          end

          true
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
          local owners_key = KEYS[3]
          local worker_id = ARGV[1]
          local current_time = ARGV[2]

          local test = redis.call('rpop', queue_key)
          if test then
            redis.call('zadd', zset_key, current_time, test)
            redis.call('hset', owners_key, test, worker_id)
            return test
          else
            return nil
          end
        }
        def try_to_reserve_test
          eval_script(
            RESERVE_TEST,
            keys: [key('queue'), key('running'), key('owners')],
            argv: [worker_id, Time.now.to_f],
          )
        end

        RESERVE_LOST_TEST = %{
          local zset_key = KEYS[1]
          local owners_key = KEYS[2]
          local worker_id = ARGV[1]
          local current_time = ARGV[2]
          local timeout = ARGV[3]

          local test = redis.call('zrangebyscore', zset_key, 0, current_time - timeout)[1]
          if test then
            redis.call('zadd', zset_key, current_time, test)
            redis.call('hset', owners_key, test, worker_id)
            return test
          else
            return nil
          end
        }
        def try_to_reserve_lost_test
          eval_script(
            RESERVE_LOST_TEST,
            keys: [key('running'), key('owners')],
            argv: [worker_id, Time.now.to_f, timeout],
          )
        end

        ACKNOWLEDGE = %{
          local zset_key = KEYS[1]
          local processed_count_key = KEYS[2]
          local owners_key = KEYS[3]
          local worker_id = ARGV[1]
          local test = ARGV[2]

          if redis.call('hget', owners_key, test) == worker_id then
            redis.call('hdel', owners_key, test)
            if redis.call('zrem', zset_key, test) == 1 then
              redis.call('incr', processed_count_key)
              return true
            end
          end

          return false
        }
        def ack(test)
          redis.lpush(key('worker', worker_id, 'queue'), test)
          eval_script(
            ACKNOWLEDGE,
            keys: [key('running'), key('processed'), key('owners')],
            argv: [worker_id, test],
          ) == 1
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
