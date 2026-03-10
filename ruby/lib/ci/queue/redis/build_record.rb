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

        def record_error(id, payload, stat_delta: nil)
          # Run acknowledge first so we know whether we're the first to ack
          acknowledged = @queue.acknowledge(id, error: payload)

          if acknowledged
            # We were the first to ack; another worker already ack'd would get falsy from SADD
            @queue.increment_test_failed
            # Only the acknowledging worker's stats include this failure (others skip increment when ack=false).
            # Store so we can subtract it if another worker records success later.
            store_error_report_delta(id, stat_delta) if stat_delta && stat_delta.any?
          end
          # Return so caller can roll back local counter when not acknowledged
          !!acknowledged
        end

        def record_success(id, skip_flaky_record: false)
          acknowledged, error_reports_deleted_count, requeued_count, delta_json = redis.multi do |transaction|
            @queue.acknowledge(id, pipeline: transaction)
            transaction.hdel(key('error-reports'), id)
            transaction.hget(key('requeues-count'), id)
            transaction.hget(key('error-report-deltas'), id)
          end
          # When we're replacing a failure, subtract the (single) acknowledging worker's stat contribution
          if error_reports_deleted_count.to_i > 0 && delta_json
            apply_error_report_delta_correction(delta_json)
            redis.hdel(key('error-report-deltas'), id)
          end
          record_flaky(id) if !skip_flaky_record && (error_reports_deleted_count.to_i > 0 || requeued_count.to_i > 0)
          # Count this run when we ack'd or when we replaced a failure (so stats delta is applied)
          !!(acknowledged || error_reports_deleted_count.to_i > 0)
        end

        def record_requeue(id)
          true
        end

        def record_stats(stats = nil, pipeline: nil)
          return unless stats
          if pipeline
            stats.each do |stat_name, stat_value|
              pipeline.hset(key(stat_name), config.worker_id, stat_value)
              pipeline.expire(key(stat_name), config.redis_ttl)
            end
          else
            redis.pipelined do |p|
              record_stats(stats, pipeline: p)
            end
          end
        end

        # Apply a delta to this worker's stats in Redis (HINCRBY). Use this instead of
        # record_stats when recording per-test so we never overwrite and correction sticks.
        def record_stats_delta(delta, pipeline: nil)
          return if delta.nil? || delta.empty?
          apply_delta = lambda do |p|
            delta.each do |stat_name, value|
              next unless value.is_a?(Numeric) || value.to_s.match?(/\A-?\d+\.?\d*\z/)
              p.hincrbyfloat(key(stat_name), config.worker_id.to_s, value.to_f)
              p.expire(key(stat_name), config.redis_ttl)
            end
          end
          if pipeline
            apply_delta.call(pipeline)
          else
            redis.pipelined { |p| apply_delta.call(p) }
          end
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

        def record_worker_profile(profile)
          redis.pipelined do |pipeline|
            pipeline.hset(key('worker-profiles'), config.worker_id, JSON.dump(profile))
            pipeline.expire(key('worker-profiles'), config.redis_ttl)
          end
        end

        def worker_profiles
          raw = redis.hgetall(key('worker-profiles'))
          raw.transform_values { |v| JSON.parse(v) }
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

        def key(*args)
          ['build', config.build_id, *args].join(':')
        end

        def store_error_report_delta(test_id, stat_delta)
          # Only the acknowledging worker's stats include this test; store their delta for correction on success
          payload = { 'worker_id' => config.worker_id.to_s }.merge(stat_delta)
          redis.hset(key('error-report-deltas'), test_id, JSON.generate(payload))
          redis.expire(key('error-report-deltas'), config.redis_ttl)
        end

        def apply_error_report_delta_correction(delta_json)
          delta = JSON.parse(delta_json)
          worker_id = delta.delete('worker_id')&.to_s
          return if worker_id.nil? || worker_id.empty? || delta.empty?

          redis.pipelined do |pipeline|
            delta.each do |stat_name, value|
              next unless value.is_a?(Numeric) || value.to_s.match?(/\A-?\d+\.?\d*\z/)

              pipeline.hincrbyfloat(key(stat_name), worker_id, -value.to_f)
              pipeline.expire(key(stat_name), config.redis_ttl)
            end
          end
        end
      end
    end
  end
end
