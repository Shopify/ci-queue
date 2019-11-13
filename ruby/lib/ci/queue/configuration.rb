require 'minitest/queue/env_configuration'
require 'minitest/queue/argv_configuration'

module CI
  module Queue
    class Configuration
      def initialize(env, argv)
        @env_config = CI::Queue::EnvConfiguration.new(env)
        @argv_config = CI::Queue::ArgvConfiguration.new(argv)
      end

      def build_id
        @build_id ||= fetch_build_id(argv_config.namespace, env_config.build_id, argv_config.build_id)
      end

      def build_id=(new_build_id)
        @build_id = new_build_id
      end

      def worker_id
        @worker_id ||= argv_config.worker_id || env_config.worker_id
      end

      def grind_list
        @grind_list ||= argv_config.grind_list
      end

      def grind_count
        @grind_count ||= argv_config.grind_count
      end

      def statsd_endpoint
        @statsd_endpoint ||= env_config.statsd_endpoint
      end

      def failing_test
        @failing_test ||= argv_config.failing_test
      end

      def failure_file
        @failure_file ||= argv_config.failure_file
      end

      def circuit_breakers
        @circuit_breakers ||= [CircuitBreaker::Disabled]
      end

      def max_requeues
        @max_requeues ||= argv_config.max_requeues || 0
      end

      def requeue_tolerance
        @requeue_tolerance ||= argv_config.requeue_tolerance || 0
      end

      def queue_url
        @queue_url ||= argv_config.queue_url || env_config.queue_url
      end

      def flaky_tests
        @flaky_tests ||= env_config.flaky_tests || []
      end

      def timeout
        @timeout ||= argv_config.timeout || 30
      end

      def seed
        @seed ||= argv_config.seed || env_config.seed || build_id
      end

      def max_consecutive_failures=(max)
        return unless max
        @circuit_breakers << CircuitBreaker.new(max_consecutive_failures: max)
      end

      def max_duration=(duration)
        return unless duration
        @circuit_breakers << CircuitBreaker::Timeout.new(duration: duration)
      end

      def global_max_requeues(tests_count)
        (tests_count * Float(requeue_tolerance)).ceil
      end

      def flaky?(test_id)
        flaky_tests.include?(test_id)
      end

      private

      attr_reader :env_config, :argv_config

      def fetch_build_id(namespace, env_build_id, argv_buid_id)
        id = argv_buid_id || env_build_id
        if namespace
          "#{namespace}:#{id}"
        else
          id
        end
      end
    end
  end
end
