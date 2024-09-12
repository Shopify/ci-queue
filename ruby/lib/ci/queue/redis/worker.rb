# frozen_string_literal: true
require 'ci/queue/static'
require 'set'

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

        def initialize(redis, config)
          @reserved_test = nil
          @shutdown_required = false
          super(redis, config)
        end

        def distributed?
          true
        end

        def populate(tests, random: Random.new)
          @index = tests.map { |t| [t.id, t] }.to_h
          tests = Queue.shuffle(tests, random)
          push(tests.map(&:id))
          self
        end

        def populated?
          !!defined?(@index)
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
          until shutdown_required? || config.circuit_breakers.any?(&:open?) || exhausted? || max_test_failed?
            if test = reserve
              yield index.fetch(test)
            else
              sleep 0.05
            end
          end
          redis.pipelined do |pipeline|
            pipeline.expire(key('worker', worker_id, 'queue'), config.redis_ttl)
            pipeline.expire(key('processed'), config.redis_ttl)
          end
        rescue *CONNECTION_ERRORS
        end

        if ::Redis.method_defined?(:exists?)
          def retrying?
            redis.exists?(key('worker', worker_id, 'queue'))
          rescue *CONNECTION_ERRORS
            false
          end
        else
          def retrying?
            redis.exists(key('worker', worker_id, 'queue'))
          rescue *CONNECTION_ERRORS
            false
          end
        end

        def retry_queue
          failures = build.failed_tests.to_set
          log = redis.lrange(key('worker', worker_id, 'queue'), 0, -1)
          log.select! { |id| failures.include?(id) }
          log.uniq!
          log.reverse!
          Retry.new(log, config, redis: redis)
        end

        def supervisor
          Supervisor.new(redis_url, config)
        end

        def build
          @build ||= CI::Queue::Redis::BuildRecord.new(self, redis, config)
        end

        def report_worker_error(error)
          build.report_worker_error(error)
        end

        def acknowledge(test)
          test_key = test.id
          raise_on_mismatching_test(test_key)
          eval_script(
            :acknowledge,
            keys: [key('running'), key('processed'), key('owners')],
            argv: [test_key],
          ) == 1
        end

        def requeue(test, offset: Redis.requeue_offset)
          test_key = test.id
          raise_on_mismatching_test(test_key)
          global_max_requeues = config.global_max_requeues(total)

          requeued = config.max_requeues > 0 && global_max_requeues > 0 && eval_script(
            :requeue,
            keys: [
              key('processed'),
              key('requeues-count'),
              key('queue'),
              key('running'),
              key('worker', worker_id, 'queue'),
              key('owners'),
            ],
            argv: [config.max_requeues, global_max_requeues, test_key, offset],
          ) == 1

          @reserved_test = test_key unless requeued
          requeued
        end

        def release!
          eval_script(
            :release,
            keys: [key('running'), key('worker', worker_id, 'queue'), key('owners')],
            argv: [],
          )
          nil
        end

        private

        attr_reader :index

        def worker_id
          config.worker_id
        end

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

        def try_to_reserve_test
          eval_script(
            :reserve,
            keys: [
              key('queue'),
              key('running'),
              key('processed'),
              key('worker', worker_id, 'queue'),
              key('owners'),
            ],
            argv: [CI::Queue.time_now.to_f],
          )
        end

        def try_to_reserve_lost_test
          timeout = config.max_missed_heartbeat_seconds ? config.max_missed_heartbeat_seconds : config.timeout

          lost_test = eval_script(
            :reserve_lost,
            keys: [
              key('running'),
              key('completed'),
              key('worker', worker_id, 'queue'),
              key('owners'),
            ],
            argv: [CI::Queue.time_now.to_f, timeout],
          )

          if lost_test
            build.record_warning(Warnings::RESERVED_LOST_TEST, test: lost_test, timeout: config.timeout)
          end

          lost_test
        end

        def push(tests)
          @total = tests.size

          if @master = redis.setnx(key('master-status'), 'setup')
            puts "Worker electected as leader, pushing #{@total} tests to the queue."
            puts

            attempts = 0
            duration = measure do
              redis.without_reconnect do
                redis.multi do |transaction|
                  transaction.lpush(key('queue'), tests) unless tests.empty?
                  transaction.set(key('total'), @total)
                  transaction.set(key('master-status'), 'ready')

                  transaction.expire(key('queue'), config.redis_ttl)
                  transaction.expire(key('total'), config.redis_ttl)
                  transaction.expire(key('master-status'), config.redis_ttl)
                end
              rescue ::Redis::BaseError => error
                if !queue_initialized? && attempts < 3
                  puts "Retrying pushing #{@total} tests to the queue... (#{error})"
                  attempts += 1
                  retry
                end

                raise if !queue_initialized?
              end
            end

            puts "Finished pushing #{@total} tests to the queue in #{duration.round(2)}s."
          end
          register
          redis.expire(key('workers'), config.redis_ttl)
        rescue *CONNECTION_ERRORS
          raise if @master
        end

        def register
          redis.sadd(key('workers'), [worker_id])
        end
      end
    end
  end
end
