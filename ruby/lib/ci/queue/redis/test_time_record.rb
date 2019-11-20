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
          redis.pipelined do
            redis.lpush(
              test_time_key(test_name),
              duration.to_s.force_encoding(Encoding::BINARY),
            )
          end
          nil
        end

        def record_test_name(test_name)
          redis.pipelined do
            redis.lpush(
              key_to_list_all_test_names,
              test_name.force_encoding(Encoding::BINARY),
            )
          end
          nil
        end

        def fetch_all_test_names
          values = redis.pipelined do
            redis.lrange(key_to_list_all_test_names, 0, -1)
          end
          values.flatten.map(&:to_s)
        end

        def fetch_test_time(test_name)
          values = redis.pipelined do
            key = test_time_key(test_name)
            redis.lrange(key, 0, -1)
          end
          values.flatten.map(&:to_f)
        end

        def key_to_list_all_test_names
          "build:#{config.build_id}:list_of_test_names".force_encoding(Encoding::BINARY)
        end

        def test_time_key(test_name)
          "build:#{config.build_id}:#{test_name}".force_encoding(Encoding::BINARY)
        end
      end
    end
  end
end
