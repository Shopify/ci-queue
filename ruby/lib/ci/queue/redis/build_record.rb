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

        def report_worker_error(error)
          redis.pipelined do |pipeline|
            pipeline.hset(key('worker-errors'), config.worker_id, error.message)
            pipeline.expire(key('worker-errors'), config.redis_ttl)
          end
        end

        def worker_errors
          redis.hgetall(key('worker-errors'))
        end

        def reset_worker_error
          redis.hdel(key('worker-errors'), config.worker_id)
        end

        def failed_tests
          redis.hkeys(key('error-reports'))
        end

        TOTAL_KEY = "___total___"
        def requeued_tests
          requeues = redis.hgetall(key('requeues-count'))
          requeues.delete(TOTAL_KEY)
          requeues
        end

        def pop_warnings
          warnings = redis.multi do |transaction|
            transaction.lrange(key('warnings'), 0, -1)
            transaction.del(key('warnings'))
          end.first

          warnings.map { |p| Marshal.load(p) }
        end

        def record_warning(type, attributes)
          redis.rpush(key('warnings'), Marshal.dump([type, attributes]))
        end

        Test = Struct.new(:id) # Hack

        def record_error(id, payload, stats: nil)
          redis.pipelined do |pipeline|
            @queue.acknowledge(id, error: payload, pipeline: pipeline)
            record_stats(stats, pipeline: pipeline)
            @queue.increment_test_failed(pipeline: pipeline)
          end
          nil
        end

        def record_success(id, stats: nil, skip_flaky_record: false, acknowledge: true)
          @queue.acknowledge(id) if acknowledge
          error_reports_deleted_count, requeued_count, _ = redis.pipelined do |pipeline|
            pipeline.hdel(key('error-reports'), id)
            pipeline.hget(key('requeues-count'), id)
            pipeline.sadd(key('success-reports'), id)
            pipeline.expire(key('success-reports'), config.redis_ttl)
            record_stats(stats, pipeline: pipeline)
          end
          record_flaky(id) if !skip_flaky_record && (error_reports_deleted_count.to_i > 0 || requeued_count.to_i > 0)
          nil
        end

        def record_flaky(id, stats: nil)
          redis.pipelined do |pipeline|
            pipeline.sadd?(
              key('flaky-reports'),
              id.b
            )
            pipeline.expire(key('flaky-reports'), config.redis_ttl)
          end
          nil
        end

        def max_test_failed?
          return false if config.max_test_failed.nil?

          @queue.test_failures >= config.max_test_failed
        end

        def error_reports
          redis.hgetall(key('error-reports'))
        end

        def flaky_reports
          redis.smembers(key('flaky-reports'))
        end

        def fetch_stats(stat_names)
          counts = redis.pipelined do |pipeline|
            stat_names.each { |c| pipeline.hvals(key(c)) }
          end
          sum_counts = counts.map do |values|
            values.map(&:to_f).inject(:+).to_f
          end
          stat_names.zip(sum_counts).to_h
        end

        def reset_stats(stat_names)
          redis.pipelined do |pipeline|
            stat_names.each do |stat_name|
              pipeline.hdel(key(stat_name), config.worker_id)
            end
          end
        end

        private

        attr_reader :config, :redis

        def record_stats(stats, pipeline: redis)
          return unless stats
          stats.each do |stat_name, stat_value|
            pipeline.hset(key(stat_name), config.worker_id, stat_value)
            pipeline.expire(key(stat_name), config.redis_ttl)
          end
        end

        def key(*args)
          ['build', config.build_id, *args].join(':')
        end
      end
    end
  end
end
