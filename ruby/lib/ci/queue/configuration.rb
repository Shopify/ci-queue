# frozen_string_literal: true
module CI
  module Queue
    class Configuration
      attr_accessor :timeout, :worker_id, :max_requeues, :grind_count, :failure_file, :export_flaky_tests_file
      attr_accessor :requeue_tolerance, :namespace, :failing_test, :statsd_endpoint
      attr_accessor :max_test_duration, :max_test_duration_percentile, :track_test_duration
      attr_accessor :max_test_failed, :redis_ttl, :warnings_file, :debug_log, :max_missed_heartbeat_seconds
      attr_accessor :lazy_load, :test_helpers, :test_files_path
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
            debug_log: env['CI_QUEUE_DEBUG_LOG'],
            max_requeues: env['CI_QUEUE_MAX_REQUEUES']&.to_i || 0,
            requeue_tolerance: env['CI_QUEUE_REQUEUE_TOLERANCE']&.to_f || 0,
            lazy_load: env['CI_QUEUE_LAZY_LOAD'] == 'true',
            test_helpers: env['CI_QUEUE_TEST_HELPERS'],
            test_files_path: env['CI_QUEUE_TEST_FILES'],
          )
        end

        def load_flaky_tests(path)
          return [] unless path
          if ::File.extname(path) == ".xml"
            require 'rexml/document'
            REXML::Document.new(::File.read(path)).elements.to_a("//testcase").map do |element|
              "#{element.attributes['classname']}##{element.attributes['name']}"
            end.to_set
          else
            ::File.readlines(path).map(&:chomp).to_set
          end
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
        export_flaky_tests_file: nil, warnings_file: nil, debug_log: nil, max_missed_heartbeat_seconds: nil,
        lazy_load: false, test_helpers: nil, test_files_path: nil)
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
        @warnings_file = warnings_file
        @debug_log = debug_log
        @max_missed_heartbeat_seconds = max_missed_heartbeat_seconds
        @lazy_load = lazy_load
        @test_helpers = test_helpers
        @test_files_path = test_files_path
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

      def lazy_load?
        @lazy_load
      end

      def test_helper_paths
        return [] unless @test_helpers

        @test_helpers.split(',').map(&:strip)
      end
    end
  end
end
