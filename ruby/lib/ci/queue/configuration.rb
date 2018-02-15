module CI
  module Queue
    class Configuration
      attr_accessor :timeout, :build_id, :worker_id, :max_requeues, :requeue_tolerance, :namespace, :seed, :failing_test, :test_runnables_provider

      class << self
        def from_env(env)
          new(
            build_id: env['CIRCLE_BUILD_URL'] || env['BUILDKITE_BUILD_ID'] || env['TRAVIS_BUILD_ID'],
            worker_id: env['CIRCLE_NODE_INDEX'] || env['BUILDKITE_PARALLEL_JOB'],
            seed: env['CIRCLE_SHA1'] || env['BUILDKITE_COMMIT'] || env['TRAVIS_COMMIT'],
          )
        end
      end

      def initialize(
        timeout: 30, build_id: nil, worker_id: nil, max_requeues: 0, requeue_tolerance: 0,
        namespace: nil, seed: nil, :test_runnables_provider: Minitest::Test
      )
        @namespace = namespace
        @timeout = timeout
        @build_id = build_id
        @worker_id = worker_id
        @max_requeues = max_requeues
        @requeue_tolerance = requeue_tolerance
        @seed = seed
        @test_runnables_provider = test_runnables_provider
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
