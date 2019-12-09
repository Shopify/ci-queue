# frozen_string_literal: true
module CI
  module Queue
    module Redis
      class BuildRecord
        def initialize(queue, redis, config)
          @queue = queue
          @redis = redis
          @config = config
        end

        def progress
          @queue.progress
        end

        def queue_exhausted?
          @queue.exhausted?
        end

        def failed_tests
          redis.hkeys(key('error-reports'))
        end

        def pop_warnings
          warnings = redis.multi do
            redis.lrange(key('warnings'), 0, -1)
            redis.del(key('warnings'))
          end.first

          warnings.map { |p| Marshal.load(p) }
        end

        def record_warning(type, attributes)
          redis.rpush(key('warnings'), Marshal.dump([type, attributes]))
        end

        def record_error(id, payload, stats: nil)
          redis.pipelined do
            redis.hset(
              key('error-reports'),
              id.dup.force_encoding(Encoding::BINARY),
              payload.dup.force_encoding(Encoding::BINARY),
            )
            record_stats(stats)
          end
          nil
        end

        def record_success(id, stats: nil)
          redis.pipelined do
            redis.hdel(key('error-reports'), id.dup.force_encoding(Encoding::BINARY))
            record_stats(stats)
          end
          nil
        end

        def error_reports
          redis.hgetall(key('error-reports'))
        end

        def fetch_stats(stat_names)
          counts = redis.pipelined do
            stat_names.each { |c| redis.hvals(key(c)) }
          end
          stat_names.zip(counts.map { |values| values.map(&:to_f).inject(:+).to_f }).to_h
        end

        def reset_stats(stat_names)
          redis.pipelined do
            stat_names.each do |stat_name|
              redis.hdel(key(stat_name), config.worker_id)
            end
          end
        end

        private

        attr_reader :config, :redis

        def record_stats(stats)
          return unless stats
          stats.each do |stat_name, stat_value|
            redis.hset(key(stat_name), config.worker_id, stat_value)
          end
        end

        def key(*args)
          ['build', config.build_id, *args].join(':')
        end
      end
    end
  end
end
