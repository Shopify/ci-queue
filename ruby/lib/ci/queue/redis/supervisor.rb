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
          raw = redis.get(key('total'))
          value = raw.to_i
          if value <= 0 && ENV['CI_QUEUE_DEBUG']
            ttl = redis.ttl(key('total'))
            streaming_complete = redis.get(key('streaming-complete'))
            master_status = redis.get(key('master-status'))
            processed_count = redis.scard(key('processed'))
            puts "[ci-queue] Supervisor#total: raw=#{raw.inspect}, value=#{value}, " \
              "key=#{key('total')}, ttl=#{ttl}, streaming_complete=#{streaming_complete.inspect}, " \
              "master_status=#{master_status.inspect}, processed_count=#{processed_count}"
          end
          value
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
          until exhausted? || @time_left <= 0 || max_test_failed? || @time_left_with_no_workers <= 0
            @time_left -= 1
            sleep 1

            if active_workers?
              @time_left_with_no_workers = config.inactive_workers_timeout
            else
              @time_left_with_no_workers -= 1
            end

            yield if block_given?
          end

          exhausted?
        rescue CI::Queue::Redis::LostMaster
          false
        end

        attr_reader :time_left, :time_left_with_no_workers

        private

        def active_workers?
          # if there are running jobs we assume there are still agents active
          redis.zrangebyscore(key('running'), CI::Queue.time_now.to_f - config.timeout, "+inf", limit: [0,1]).count > 0
        end
      end
    end
  end
end
