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
          eval_script(
            :acknowledge,
            keys: [key('running'), key('processed')],
            argv: [worker_id, test],
          ) == 1
        end

        def requeue(test, offset: Redis.requeue_offset)
          raise_on_mismatching_test(test)

          requeued = eval_script(
            :requeue,
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
        }

        def try_to_reserve_test
          eval_script(
            :reserve,
            keys: [key('queue'), key('running'), key('processed'), key('worker', worker_id, 'queue')],
            argv: [Time.now.to_f],
          )
        end

        def try_to_reserve_lost_test
          eval_script(
            :reserve_lost,
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
