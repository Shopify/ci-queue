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

        def record_error(payload)
          redis.pipelined do |pipeline|
            pipeline.lpush(
              key('error-reports'),
              payload,
            )
            pipeline.expire(key('error-reports'), config.redis_ttl)
          end
          true
        end

        def record_success
          true
        end

        def record_requeue
          true
        end

        def record_warning(_,_)
          #do nothing
        end

        def error_reports
          redis.lrange(key('error-reports'), 0, -1)
        end

        def fetch_stats(stat_names)
          counts = redis.pipelined do |pipeline|
            stat_names.each { |c| pipeline.hvals(key(c)) }
          end
          stat_names.zip(counts.map { |values| values.map(&:to_f).inject(:+).to_f }).to_h
        end

        def pop_warnings
          []
        end

        alias failed_tests error_reports

        def record_stats(stats, pipeline: redis)
          return unless stats
          stats.each do |stat_name, stat_value|
            pipeline.hset(key(stat_name), config.worker_id, stat_value)
            pipeline.expire(key(stat_name), config.redis_ttl)
          end
        end

        private

        attr_reader :redis, :config

        def key(*args)
          KeyShortener.key(config.build_id, *args)
        end
      end
    end
  end
end
