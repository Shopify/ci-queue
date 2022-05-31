# frozen_string_literal: true
module CI
  module Queue
    module Redis
      class TestTimeRecord < Worker
        def record(test_name, duration)
          record_test_time(test_name, duration)
          record_test_name(test_name)
        end

        def fetch
          fetch_all_test_names.each_with_object({}) do |test_name, test_time_hash|
            test_time_hash[test_name] = fetch_test_time(test_name)
          end
        end

        private

        attr_reader :redis

        def record_test_time(test_name, duration)
          redis.pipelined do |pipeline|
            pipeline.lpush(
              test_time_key(test_name),
              duration.to_s.force_encoding(Encoding::BINARY),
            )
            pipeline.expire(test_time_key(test_name), config.redis_ttl)
          end
          nil
        end

        def record_test_name(test_name)
          redis.pipelined do |pipeline|
            pipeline.lpush(
              all_test_names_key,
              test_name.dup.force_encoding(Encoding::BINARY),
            )
            pipeline.expire(all_test_names_key, config.redis_ttl)
          end
          nil
        end

        def fetch_all_test_names
          values = redis.pipelined do |pipeline|
            pipeline.lrange(all_test_names_key, 0, -1)
          end
          values.flatten.map(&:to_s)
        end

        def fetch_test_time(test_name)
          key = test_time_key(test_name)
          redis.lrange(key, 0, -1).map(&:to_f)
        end

        def all_test_names_key
          "build:#{config.build_id}:list_of_test_names".dup.force_encoding(Encoding::BINARY)
        end

        def test_time_key(test_name)
          "build:#{config.build_id}:#{test_name}".dup.force_encoding(Encoding::BINARY)
        end
      end
    end
  end
end
