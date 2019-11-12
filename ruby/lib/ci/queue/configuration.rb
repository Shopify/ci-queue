require 'minitest/queue/parse_env'
require 'minitest/queue/parse_argv'

module CI
  module Queue
    class Configuration
      Config = Struct.new(
        :build_id,
        :worker_id,
        :grind_list,
        :grind_count,
        :statsd_endpoint,
        :failing_test,
        :failure_file,
        :seed,
        :circuit_breakers,
        :max_requeues,
        :requeue_tolerance,
        :queue_url,
        :flaky_tests,
        :timeout,
      ) do
        def max_consecutive_failures=(max)
          return unless max
          circuit_breakers << CircuitBreaker.new(max_consecutive_failures: max)
        end

        def max_duration=(duration)
          return unless duration
          circuit_breakers << CircuitBreaker::Timeout.new(duration: duration)
        end

        def global_max_requeues(tests_count)
          (tests_count * Float(requeue_tolerance)).ceil
        end

        def flaky?(test_id)
          flaky_tests.include?(test_id)
        end
      end

      attr_reader :config

      def initialize(env, argv)
        env_config = CI::Queue::ParseEnv.parse(env)
        argv_config = CI::Queue::ParseArgv.new(argv).config

        @config = Config.new()
        @config.worker_id = argv_config.worker_id || env_config.worker_id
        @config.grind_list = argv_config.grind_list
        @config.grind_count = argv_config.grind_count
        @config.statsd_endpoint = env_config.statsd_endpoint
        @config.failing_test = argv_config.failing_test
        @config.failure_file = argv_config.failure_file
        @config.circuit_breakers = [CircuitBreaker::Disabled]
        @config.max_requeues = argv_config.max_requeues || 0
        @config.requeue_tolerance = argv_config.requeue_tolerance || 0
        @config.queue_url = argv_config.queue_url || env_config.queue_url
        @config.flaky_tests = env_config.flaky_tests || []
        @config.timeout = argv_config.timeout || 30
        build_id = fetch_build_id(argv_config.namespace, env_config.build_id, argv_config.build_id)
        @config.build_id = build_id
        @config.seed = argv_config.seed || env_config.seed || build_id
      end

      private

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

# module CI
#   module Queue
#     class Configuration
#       attr_accessor :timeout, :build_id, :worker_id, :max_requeues, :grind_count, :failure_file
#       attr_accessor :requeue_tolerance, :namespace, :seed, :failing_test, :statsd_endpoint
#       attr_reader :circuit_breakers

#       class << self
#         def from_env(env)
#           new(
#             build_id: env['CIRCLE_BUILD_URL'] || env['BUILDKITE_BUILD_ID'] || env['TRAVIS_BUILD_ID'] || env['HEROKU_TEST_RUN_ID'] || env['SEMAPHORE_PIPELINE_ID'],
#             worker_id:
#             seed: ,
#             flaky_tests: load_flaky_tests(env['CI_QUEUE_FLAKY_TESTS']),
#             statsd_endpoint: env['CI_QUEUE_STATSD_ADDR'],
#           )
#         end


#       end

#       def initialize(
#         timeout: 30, build_id: nil, worker_id: nil, max_requeues: 0, requeue_tolerance: 0,
#         namespace: nil, seed: nil, flaky_tests: [], statsd_endpoint: nil, max_consecutive_failures: nil,
#         grind_count: nil, max_duration: nil, failure_file: nil
#       )
#         @circuit_breakers = [CircuitBreaker::Disabled]
#         @build_id = build_id
#         @failure_file = failure_file
#         @flaky_tests = flaky_tests
#         @grind_count = grind_count
#         @max_requeues = max_requeues
#         @namespace = namespace
#         @requeue_tolerance = requeue_tolerance
#         @seed = seed
#         @statsd_endpoint = statsd_endpoint
#         @timeout = timeout
#         @worker_id = worker_id
#         self.max_duration = max_duration
#         self.max_consecutive_failures = max_consecutive_failures
#       end

#       # def max_consecutive_failures=(max)
#       #   if max
#       #     @circuit_breakers << CircuitBreaker.new(max_consecutive_failures: max)
#       #   end
#       # end

#       # def max_duration=(duration)
#       #   if duration
#       #     @circuit_breakers << CircuitBreaker::Timeout.new(duration: duration)
#       #   end
#       # end

#       def flaky?(test)
#         @flaky_tests.include?(test.id)
#       end

#       # def seed
#       #   @seed || build_id
#       # end

#       # def build_id
#       #   if namespace
#       #     "#{namespace}:#{@build_id}"
#       #   else
#       #     @build_id
#       #   end
#       # end

#       def global_max_requeues(tests_count)
#         (tests_count * Float(requeue_tolerance)).ceil
#       end
#     end
#   end
# end
