# frozen_string_literal: true

require "benchmark"
require "forwardable"

module CI
  module Queue
    class MultiQueue
      include Common
      extend Forwardable

      class << self
        def from_uri(uri, config)
          new(uri.to_s, config)
        end
      end

      attr_reader :redis_url, :config, :redis, :current_queue

      def initialize(redis_url, config)
        @redis_url = redis_url
        @config = config
        if ::Redis::VERSION > "5.0.0"
          @redis = ::Redis.new(
            url: redis_url
          )
        else
          @redis = ::Redis.new(url: redis_url)
        end
        @shutdown_required = false
        @starting_queue_assigned = false
        @current_queue = starting_queue
      end

      def distributed?
        true
      end

      def retrying?
        queues.any?(&:retrying?)
      end

      def expired?
        queues.any?(&:expired?)
      end

      def exhausted?
        queues.all?(&:exhausted?)
      end

      def total
        total = 0
        queues.each do |q|
          t = q.supervisor.total
          puts "Queue #{q.name}, total: #{t}"
          total += t if t
        end
        total
      end

      def size
        queues.sum(&:size)
      end

      def progress
        total - size
      end

      def remaining
        queues.sum(&:remaining)
      end

      def running
        queues.sum(&:running)
      end

      def poll
        queues.each do |q|
          @current_queue = q

          begin
            if q.exhausted?
              puts "# All tests executed in #{q.name} queue, skipping..."
              next
            end

            prev_loaded_tests = Minitest.loaded_tests
            q.load_tests!
            q.populate(Minitest.loaded_tests - prev_loaded_tests, random: ordering_seed, &:id) unless q.populated?

            puts "# Processing #{q.size} tests in #{q.name} queue..."

            q.poll do |test|
              yield test
            end
          rescue *CI::Queue::Redis::Base::CONNECTION_ERRORS
          end
        end
      end

      def max_test_failed?
        return false if config.max_test_failed.nil?

        queues.sum(&:test_failed) >= config.max_test_failed
      end

      def build
        @build ||= CI::Queue::Redis::BuildRecord.new(self, redis, config)
      end

      def supervisor
        @supervisor ||= Supervisor.new(multi_queue: self)
      end

      def retry_queue
        # TODO: implement
      end

      def created_at=(time)
        queues.each { |q| q.created_at = time }
      end

      def shutdown!
        @shutdown_required = true
      end

      def shutdown_required?
        @shutdown_required
      end

      def_delegators :@current_queue, :acknowledge, :requeue, :populate, :release!, :increment_test_failed

      # TODO: move heartbeat into module
      def boot_heartbeat_process!; end

      def with_heartbeat(id)
        yield
      end

      def ensure_heartbeat_thread_alive!; end

      def stop_heartbeat!; end

      class SubQueue < SimpleDelegator
        attr_reader :name

        def initialize(worker:, multi_queue:, name:, test_files:, preload_files:)
          super(worker)
          @name = name
          @test_files = test_files
          @multi_queue = multi_queue
          @preload_files = preload_files
          @preloaded = false
        end

        def load_tests!
          duration = Benchmark.realtime do
            @test_files.each do |test_file|
              require ::File.expand_path(test_file)
            end
          end

          puts "# Loaded #{@test_files.size} test files in #{name} queue in #{duration.round(2)} seconds"
        end

        def max_test_failed?
          @multi_queue.max_test_failed?
        end

        def preload_files!
          return if @preload_files.empty? || @preloaded

          @preload_files.each do |file|
            require ::File.expand_path(file)
          end

          @preloaded = true
        end
      end

      class Supervisor < SimpleDelegator
        def initialize(multi_queue:)
          super(multi_queue)
          @multi_queue = multi_queue
        end

        def wait_for_workers
          wait_statuses = @multi_queue.queues.map do |q|
            status = q.supervisor.wait_for_workers do
              yield
            end
            puts "# Queue #{q.name} finished running with status #{status}"
            status
          end
          wait_statuses.all? { |status| status == true }
        end

        def queue_initialized?
          all_queues_initialized = true
          @multi_queue.queues.each do |q|
            puts "Queue #{q.name} initialized: #{q.queue_initialized?}"
            unless q.queue_initialized?
              puts "Queue #{q.name} was not initialized"
              all_queues_initialized = false
            end
          end
          all_queues_initialized
        end
      end

      def queues
        @queues ||= @config.multi_queue_config["queues"].map do |name, files|
          sub_queue_config = @config.dup.tap { |c| c.namespace = name }
          SubQueue.new(
            worker:CI::Queue::Redis::Worker.new(@redis_url, sub_queue_config, @redis),
            multi_queue: self, name: name, test_files: files, preload_files: @config.multi_queue_config["preload_files"]
          )
        end
        @queues
      end

      private

      def starting_queue
        return queues.first if @starting_queue_assigned

        starting_queue = queues.delete_at(@config.worker_id.to_i % queues.size)
        queues.unshift(starting_queue)
        @starting_queue_assigned = true
        starting_queue
      end

      # Worth extracting this into a module?
      def ordering_seed
        if @config.seed
          Random.new(Digest::MD5.hexdigest(@config.seed).to_i(16))
        else
          Random.new
        end
      end
    end
  end
end
