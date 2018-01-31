module CI
  module Queue
    module Redis
      class Supervisor < Base
        def master?
          false
        end

        def total
          wait_for_master(timeout: config.timeout)
          redis.get(key('total')).to_i
        end

        def build
          @build ||= CI::Queue::Redis::BuildRecord.new(self, redis, config)
        end

        def minitest_reporters
          require 'minitest/reporters/redis_reporter'
          @reporters ||= [
            Minitest::Reporters::RedisReporter::Summary.new(build: build)
          ]
        end

        def wait_for_workers
          return false unless wait_for_master(timeout: config.timeout)

          time_left = config.timeout
          until exhausted? || time_left <= 0
            sleep 0.1
            time_left -= 0.1
          end
          exhausted?
        rescue CI::Queue::Redis::LostMaster
          false
        end
      end
    end
  end
end