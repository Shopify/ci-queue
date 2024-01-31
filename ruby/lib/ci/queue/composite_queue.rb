# frozen_string_literal: true

module CI
  module Queue
    class CompositeQueue
      include Common

      class << self
        def from_uri(uri, config)
          new(uri.to_s, config)
        end
      end

      attr_reader :redis_url, :config, :redis

      def initialize(redis_url, config)
        @redis_url = redis_url
        @config = config
        @redis = ::Redis.new(url: redis_url)
      end

      attr_reader :current_queue

      def distributed?
        true
      end

      def retrying?
        queues.any?(&:retrying?)
      end

      def created_at=(time)
        queues.each { |q| q.created_at = time }
      end

      def build
        @build ||= CI::Queue::Redis::BuildRecord.new(self, redis, config)
      end

      def progress
        supervisor.progress
      end

      def exhausted?
        queues.all?(&:exhausted?)
      end

      def expired?
        queues.any?(&:expired?)
      end

      def populate(tests, random: Random.new)
        @current_queue.populate(tests, random: random)
      end

      # todo move heartbeat into module
      def boot_heartbeat_process!; end

      def with_heartbeat(id)
        yield
      end

      def stop_heartbeat!; end

      def acknowledge(test)
        @current_queue.acknowledge(test)
      end

      def requeue(test)
        @current_queue.requeue(test)
      end

      def increment_test_failed
        queues.each(&:increment_test_failed)
      end

      def max_test_failed?
        queues.any?(&:max_test_failed?)
      end

      def poll
        queues.each do |worker|
          @current_queue = worker

          if worker.rescue_connection_errors { worker.exhausted? }
            puts "# All tests executed in #{worker.name}, skipping..."
            next
          end

          prev_loaded_tests = Minitest.loaded_tests
          worker.load_tests!

          tests_to_run = Minitest.loaded_tests - prev_loaded_tests

          worker.populate(tests_to_run, random: ordering_seed, &:id) unless worker.populated?
          puts "# Processing queue #{worker.name} (#{worker.size} tests)"

          worker.poll do |test|
            yield test
          end

          puts ""
        end
      end

      class CompositeSupervisor
        def initialize(queues, build, config )
          @queues = queues
          @build = build
          @config = config
        end

        attr_reader :queues, :build, :config

        def exhausted?
          queues.all?(:exhausted?)
        end

        def wait_for_workers
          require 'benchmark'

          report_timeout = config.report_timeout
          queue_init_timeout = config.queue_init_timeout

          queues.each do |queue|
            duration = Benchmark.measure do
              queue.wait_for_workers(report_timeout: report_timeout, queue_init_timeout: queue_init_timeout)
            end

            report_timeout = [report_timeout - duration.real.to_i, 0].max
            queue_init_timeout = [queue_init_timeout - duration.real.to_i, 0].max
          end
        end

        def progress
          queues.sum(&:progress)
        end
      end

      def supervisor
        @supervisor ||= CompositeSupervisor.new(queues.map(&:supervisor), build, config)
      end

      private

      def ordering_seed
        if @config.seed
          Random.new(Digest::MD5.hexdigest(@config.seed).to_i(16))
        else
          Random.new
        end
      end

      class SubQueueWorker < SimpleDelegator
        def initialize(worker, name, files)
          super(worker)
          @name = name
          @files = files
        end

        def load_tests!
          files.each do |file|
            require ::File.expand_path(file)
          end
        end

        attr_reader :name

        private

        attr_reader :files
      end

      def queues
        @queues ||= @config.multi_queue_config.map do |name, files|
          sub_queue_config = @config.dup.tap do |config|
            config.namespace = name
          end
          SubQueueWorker.new(CI::Queue::Redis::Worker.new(@redis_url, sub_queue_config), name, files)
        end.shuffle(random: Random.new(Digest::MD5.hexdigest(config.worker_id.to_s).to_i(16)))
        @current_queue ||= @queues.first
        @queues
      end
    end
  end
end
