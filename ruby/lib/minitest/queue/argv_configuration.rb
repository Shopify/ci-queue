require 'optparse'

module CI
  module Queue
    class ArgvConfiguration
      attr_reader :queue_url
      attr_reader :grind_list
      attr_reader :grind_count
      attr_reader :build_id
      attr_reader :namespace
      attr_reader :timeout
      attr_reader :load_paths
      attr_reader :seed
      attr_reader :worker_id
      attr_reader :max_requeues
      attr_reader :max_duration
      attr_reader :requeue_tolerance
      attr_reader :failure_file
      attr_reader :max_consecutive_failures
      attr_reader :failing_test

      def self.help
        parse_argv_instance = CI::Queue::ArgvConfiguration.new({})
        parse_argv_instance.parser.help
      end

      def initialize(argv)
        parser.parse!(argv)
      end

      def parser
        parser ||= OptionParser.new do |opts|
          opts.banner = "Usage: minitest-queue [options] COMMAND [ARGS]"

          opts.separator ""
          opts.separator "Example: minitest-queue -Itest --queue redis://example.com run test/**/*_test.rb"

          opts.separator ""
          opts.separator "GLOBAL OPTIONS"


          help = <<~EOS
            URL of the queue, e.g. redis://example.com.
            Defaults to $CI_QUEUE_URL if set.
          EOS
          opts.separator ""
          opts.on('--queue URL', *help) do |url|
            @queue_url = url
          end

          help = <<~EOS
            Path to the file that includes the list of tests to grind.
          EOS
          opts.separator ""
          opts.on('--grind-list PATH', *help) do |url|
            @grind_list = url
          end

          help = <<~EOS
            Count defines how often each test in the grind list is going to be run.
          EOS
          opts.separator ""
          opts.on('--grind-count COUNT', *help) do |count|
            @grind_count = count.to_i
          end

          help = <<~EOS
            Unique identifier for the workload. All workers working on the same suite of tests must have the same build identifier.
            If the build is tried again, or another revision is built, this value must be different.
            It's automatically inferred on Buildkite, CircleCI, Heroku CI, and Travis.
          EOS
          opts.separator ""
          opts.on('--build BUILD_ID', *help) do |build_id|
            @build_id = build_id
          end

          help = <<~EOS
            Optional. Sets a prefix for the build id in case a single CI build runs multiple independent test suites.
              Example: --namespace integration
          EOS
          opts.separator ""
          opts.on('--namespace NAMESPACE', *help) do |namespace|
            @namespace = namespace
          end

          opts.separator ""
          opts.separator "COMMANDS"
          opts.separator ""
          opts.separator "    run [TEST_FILES...]: Participate in leader election, and then work off the test queue."

          help = <<~EOS
            Specify a timeout after which if a test haven't completed, it will be picked up by another worker.
            It is very important to set this vlaue higher than the slowest test in the suite, otherwise performance will be impacted.
            Defaults to 30 seconds.
          EOS
          opts.separator ""
          opts.on('--timeout TIMEOUT', *help) do |timeout|
            @timeout = Float(timeout)
          end

          help = <<~EOS
            Specify $LOAD_PATH directory, similar to Ruby's -I
          EOS
          opts.separator ""
          opts.on('-IPATHS', *help) do |paths|
            @load_paths = paths
          end

          help = <<~EOS
            Sepcify a seed used to shuffle the test suite.
            On Buildkite, CircleCI, Heroku CI, and Travis, the commit revision will be used by default.
          EOS
          opts.separator ""
          opts.on('--seed SEED', *help) do |seed|
            @seed = seed
          end

          help = <<~EOS
            A unique identifier for this worker, It must be consistent to allow retries.
            If not specified, retries won't be available.
            It's automatically inferred on Buildkite, Heroku CI, and CircleCI.
          EOS
          opts.separator ""
          opts.on('--worker WORKER_ID', *help) do |worker_id|
            @worker_id = worker_id
          end

          help = <<~EOS
            Defines how many time a single test can be requeued.
            Defaults to 0.
          EOS
          opts.separator ""
          opts.on('--max-requeues MAX', *help) do |max|
            @max_requeues = Integer(max)
          end

          help = <<~EOS
            Defines how long ci-queue should maximally run in seconds
            Defaults to none.
          EOS
          opts.separator ""
          opts.on('--max-duration SECONDS', *help) do |max|
            @max_duration = Integer(max)
          end

          help = <<~EOS
            Defines how many requeues can happen overall, based on the test suite size. e.g 0.05 for 5%.
            Defaults to 0.
          EOS
          opts.separator ""
          opts.on('--requeue-tolerance RATIO', *help) do |ratio|
            @requeue_tolerance = Float(ratio)
          end

          help = <<~EOS
            Defines a file where the test failures are written to in the json format.
            Defaults to disabled.
          EOS
          opts.separator ""
          opts.on('--failure-file FILE', *help) do |file|
            @failure_file = file
          end

          help = <<~EOS
            Defines after how many consecutive failures the worker will be considered unhealthy and terminate itself.
            Defaults to disabled.
          EOS
          opts.separator ""
          opts.on('--max-consecutive-failures MAX', *help) do |max|
            @max_consecutive_failures = Integer(max)
          end

          opts.separator ""
          opts.separator "    retry: Replays a previous run in the same order."

          opts.separator ""
          opts.separator "    report: Wait for all workers to complete and summarize the test failures."

          opts.separator ""
          opts.separator "    bisect: bisect a test suite to find global state leaks."
          help = <<~EOS
            The identifier of the failing test.
          EOS
          opts.separator ""
          opts.on('--failing-test TEST_IDENTIFIER') do |identifier|
            @failing_test = identifier
          end
        end
      end
    end
  end
end
