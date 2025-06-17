# frozen_string_literal: true

module CI
  module Queue
    module Redis
      class Supervisor < Base
        def master?
          false
        end

        def total
          wait_for_master(timeout: config.queue_init_timeout)
          redis.get(key('total')).to_i
        end

        def build
          @build ||= CI::Queue::Redis::BuildRecord.new(self, redis, config)
        end

        def wait_for_workers
          duration = measure do
            wait_for_master(timeout: config.queue_init_timeout)
          end

          yield if block_given?

          @time_left = config.report_timeout - duration.to_i
          @time_left_with_no_workers = config.inactive_workers_timeout
          until finished? || @time_left <= 0 || max_test_failed? || @time_left_with_no_workers <= 0
            @time_left -= 1
            sleep 1

            if active_workers?
              @time_left_with_no_workers = config.inactive_workers_timeout
            else
              @time_left_with_no_workers -= 1
            end

            yield if block_given?
          end

          finished?
        rescue CI::Queue::Redis::LostMaster
          false
        end

        attr_reader :time_left, :time_left_with_no_workers

        private

        def finished?
          exhausted? && master_confirmed_all_tests_executed?
        end

        def master_confirmed_all_tests_executed?
          redis.get(key('master-confirmed-all-tests-executed')) == 'true'
        end

        def active_workers?
          # if there are running jobs we assume there are still agents active
          redis.zrangebyscore(key('running'), CI::Queue.time_now.to_f - config.timeout, "+inf", limit: [0,1]).count > 0
        end
      end
    end
  end
end
