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
          wait_for_master(timeout: config.queue_init_timeout)

          yield if block_given?

          time_left = config.timeout
          until exhausted? || time_left <= 0 || max_test_failed?
            sleep 1
            time_left -= 1

            yield if block_given?
          end
          exhausted?
        rescue CI::Queue::Redis::LostMaster
          false
        end
      end
    end
  end
end
