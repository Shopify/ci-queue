module CI
  module Queue
    class EnvConfiguration

      def initialize(env)
        @env = env
      end

      def build_id
        @build_id ||= env['CIRCLE_BUILD_URL'] || env['BUILDKITE_BUILD_ID'] || env['TRAVIS_BUILD_ID'] || env['HEROKU_TEST_RUN_ID'] || env['SEMAPHORE_PIPELINE_ID']
      end

      def worker_id
        @worker_id ||= env['CIRCLE_NODE_INDEX'] || env['BUILDKITE_PARALLEL_JOB'] || env['CI_NODE_INDEX'] || env['SEMAPHORE_JOB_ID']
      end

      def seed
        @seed ||= env['CIRCLE_SHA1'] || env['BUILDKITE_COMMIT'] || env['TRAVIS_COMMIT'] || env['HEROKU_TEST_RUN_COMMIT_VERSION'] || env['SEMAPHORE_GIT_SHA']
      end

      def statsd_endpoint
        @statsd_endpoint ||= env['CI_QUEUE_STATSD_ADDR']
      end

      def queue_url
        @queue_url ||= env['CI_QUEUE_URL']
      end

      def flaky_tests
        @flaky_tests ||= load_flaky_tests(env['CI_QUEUE_FLAKY_TESTS'])
      end

      private

      attr_reader :env

      def load_flaky_tests(path)
        return [] unless path
        ::File.readlines(path).map(&:chomp).to_set
      rescue SystemCallError
        []
      end
    end
  end
end
