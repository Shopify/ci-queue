module CI
  module Queue
    class ParseEnv
      Config = Struct.new(
        :build_id,
        :worker_id,
        :seed,
        :statsd_endpoint,
        :queue_url,
        :flaky_tests
      )

      def self.parse(env)
        config = Config.new()
        config.build_id = env['CIRCLE_BUILD_URL'] || env['BUILDKITE_BUILD_ID'] || env['TRAVIS_BUILD_ID'] || env['HEROKU_TEST_RUN_ID'] || env['SEMAPHORE_PIPELINE_ID']
        config.worker_id = env['CIRCLE_NODE_INDEX'] || env['BUILDKITE_PARALLEL_JOB'] || env['CI_NODE_INDEX'] || env['SEMAPHORE_JOB_ID']
        config.seed = env['CIRCLE_SHA1'] || env['BUILDKITE_COMMIT'] || env['TRAVIS_COMMIT'] || env['HEROKU_TEST_RUN_COMMIT_VERSION'] || env['SEMAPHORE_GIT_SHA']
        config.statsd_endpoint = env['CI_QUEUE_STATSD_ADDR']
        config.queue_url = ENV['CI_QUEUE_URL']
        config.flaky_tests = load_flaky_tests(env['CI_QUEUE_FLAKY_TESTS'])
        config
      end

      private

      def self.load_flaky_tests(path)
        return [] unless path
        ::File.readlines(path).map(&:chomp).to_set
      rescue SystemCallError
        []
      end
    end
  end
end
