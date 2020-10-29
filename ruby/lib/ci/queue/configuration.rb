# frozen_string_literal: true
module CI
  module Queue
    class Configuration
      attr_accessor :timeout, :worker_id, :max_requeues, :grind_count, :failure_file
      attr_accessor :requeue_tolerance, :namespace, :failing_test, :statsd_endpoint
      attr_accessor :max_test_duration, :max_test_duration_percentile, :track_test_duration
      attr_accessor :max_test_failed
      attr_reader :circuit_breakers
      attr_writer :seed, :build_id

      class << self
        def from_env(env)
          new(
            build_id: env['CIRCLE_BUILD_URL'] || env['BUILDKITE_BUILD_ID'] || env['TRAVIS_BUILD_ID'] || env['HEROKU_TEST_RUN_ID'] || env['SEMAPHORE_PIPELINE_ID'],
            worker_id: env['CIRCLE_NODE_INDEX'] || env['BUILDKITE_PARALLEL_JOB'] || env['CI_NODE_INDEX'] || env['SEMAPHORE_JOB_ID'],
            seed: env['CIRCLE_SHA1'] || env['BUILDKITE_COMMIT'] || env['TRAVIS_COMMIT'] || env['HEROKU_TEST_RUN_COMMIT_VERSION'] || env['SEMAPHORE_GIT_SHA'],
            flaky_tests: load_flaky_tests(env['CI_QUEUE_FLAKY_TESTS']),
            statsd_endpoint: env['CI_QUEUE_STATSD_ADDR'],
            run_flakey_tests: env['CI_QUEUE_RUN_FLAKY_TESTS']
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
        max_test_duration_percentile: 0.5, track_test_duration: false, max_test_failed: nil, run_flakey_tests: 'true'
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
        @track_test_duration = track_test_duration
        @worker_id = worker_id
        self.max_consecutive_failures = max_consecutive_failures
        self.max_duration = max_duration
        @run_flakey_tests = run_flakey_tests || 'true'
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

      def run_flakey_tests?
        %w(t true yes y 1).include?(@run_flakey_tests)
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
