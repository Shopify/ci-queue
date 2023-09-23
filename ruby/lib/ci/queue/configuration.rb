# frozen_string_literal: true
module CI
  module Queue
    class Configuration
      attr_accessor :timeout, :worker_id, :max_requeues, :grind_count, :failure_file, :export_flaky_tests_file
      attr_accessor :requeue_tolerance, :namespace, :failing_test, :statsd_endpoint
      attr_accessor :max_test_duration, :max_test_duration_percentile, :track_test_duration
      attr_accessor :max_test_failed, :redis_ttl
      attr_accessor :redis_ca_file_path, :redis_client_certificate_path, :redis_client_certificate_key_path, :redis_disable_certificate_verification
      attr_reader :circuit_breakers
      attr_writer :seed, :build_id
      attr_writer :queue_init_timeout, :report_timeout, :inactive_workers_timeout

      class << self
        def from_env(env)
          new(
            build_id: env['CIRCLE_BUILD_URL'] || env['BUILDKITE_BUILD_ID'] || env['TRAVIS_BUILD_ID'] || env['HEROKU_TEST_RUN_ID'] || env['SEMAPHORE_PIPELINE_ID'],
            worker_id: env['CIRCLE_NODE_INDEX'] || env['BUILDKITE_PARALLEL_JOB'] || env['CI_NODE_INDEX'] || env['SEMAPHORE_JOB_ID'],
            seed: env['CIRCLE_SHA1'] || env['BUILDKITE_COMMIT'] || env['TRAVIS_COMMIT'] || env['HEROKU_TEST_RUN_COMMIT_VERSION'] || env['SEMAPHORE_GIT_SHA'],
            flaky_tests: load_flaky_tests(env['CI_QUEUE_FLAKY_TESTS']),
            statsd_endpoint: env['CI_QUEUE_STATSD_ADDR'],
            redis_ttl: env['CI_QUEUE_REDIS_TTL']&.to_i ||  8 * 60 * 60,
          )
        end

        def load_flaky_tests(path)
          return [] unless path
          ::File.readlines(path).map(&:chomp).to_set
        rescue SystemCallError
          []
        end
      end

      def initialize(
        timeout: 30, build_id: nil, worker_id: nil, max_requeues: 0, requeue_tolerance: 0,
        namespace: nil, seed: nil, flaky_tests: [], statsd_endpoint: nil, max_consecutive_failures: nil,
        grind_count: nil, max_duration: nil, failure_file: nil, max_test_duration: nil,
        max_test_duration_percentile: 0.5, track_test_duration: false, max_test_failed: nil,
        queue_init_timeout: nil, redis_ttl: 8 * 60 * 60, report_timeout: nil, inactive_workers_timeout: nil,
        export_flaky_tests_file: nil, redis_ca_file_path: nil, redis_client_certificate_path: nil, redis_client_certificate_key_path: nil,
        redis_disable_certificate_verification: false
      )
        @build_id = build_id
        @circuit_breakers = [CircuitBreaker::Disabled]
        @failure_file = failure_file
        @flaky_tests = flaky_tests
        @grind_count = grind_count
        @max_requeues = max_requeues
        @max_test_duration = max_test_duration
        @max_test_duration_percentile = max_test_duration_percentile
        @max_test_failed = max_test_failed
        @namespace = namespace
        @requeue_tolerance = requeue_tolerance
        @seed = seed
        @statsd_endpoint = statsd_endpoint
        @timeout = timeout
        @queue_init_timeout = queue_init_timeout
        @track_test_duration = track_test_duration
        @worker_id = worker_id
        self.max_consecutive_failures = max_consecutive_failures
        self.max_duration = max_duration
        @redis_ttl = redis_ttl
        @report_timeout = report_timeout
        @inactive_workers_timeout = inactive_workers_timeout
        @export_flaky_tests_file = export_flaky_tests_file
        @redis_ca_file_path = redis_ca_file_path
        @redis_client_certificate_path = redis_client_certificate_path
        @redis_client_certificate_key_path = redis_client_certificate_key_path
        @redis_disable_certificate_verification = redis_disable_certificate_verification
      end

      def queue_init_timeout
        @queue_init_timeout || timeout
      end

      def report_timeout
        @report_timeout || timeout
      end

      def inactive_workers_timeout
        @inactive_workers_timeout || timeout
      end

      def max_consecutive_failures=(max)
        if max
          @circuit_breakers << CircuitBreaker::MaxConsecutiveFailures.new(max_consecutive_failures: max)
        end
      end

      def max_duration=(duration)
        if duration
          @circuit_breakers << CircuitBreaker::Timeout.new(duration: duration)
        end
      end

      def flaky?(test)
        @flaky_tests.include?(test.id)
      end

      def seed
        @seed || build_id
      end

      def build_id
        if namespace
          "#{namespace}:#{@build_id}"
        else
          @build_id
        end
      end

      def global_max_requeues(tests_count)
        (tests_count * Float(requeue_tolerance)).ceil
      end
    end
  end
end
