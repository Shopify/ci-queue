# frozen_string_literal: true
module CI
  module Queue
    module Redis
      class GrindRecord

        def initialize(queue, redis, config)
          @queue = queue
          @redis = redis
          @config = config
        end

        def record_error(payload, stats: nil)
          redis.pipelined do
            redis.lpush(
              key('error-reports'),
              payload.force_encoding(Encoding::BINARY),
            )
            record_stats(stats)
          end
          nil
        end

        def record_success(stats: nil)
          record_stats(stats)
        end

        def record_warning(_,_)
          #do nothing
        end

        def error_reports
          redis.lrange(key('error-reports'), 0, -1)
        end

        def fetch_stats(stat_names)
          counts = redis.pipelined do
            stat_names.each { |c| redis.hvals(key(c)) }
          end
          stat_names.zip(counts.map { |values| values.map(&:to_f).inject(:+).to_f }).to_h
        end

        def pop_warnings
          []
        end

        alias failed_tests error_reports

        private

        attr_reader :redis, :config

        def key(*args)
          ['build', config.build_id, *args].join(':')
        end

        def record_stats(stats)
          return unless stats
          stats.each do |stat_name, stat_value|
            redis.hset(key(stat_name), config.worker_id, stat_value)
          end
        end
      end
    end
  end
end
