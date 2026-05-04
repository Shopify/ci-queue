# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'ci/queue/common'
require 'ci/queue/build_record'

module CI
  module Queue
    # A file-system backed queue for running tests in parallel locally without Redis.
    # All workers must be on the same machine sharing the same filesystem.
    #
    # Usage:
    #   minitest-queue --queue local:///tmp/my-test-run --worker 1 run test/**/*_test.rb
    #
    # The directory is used as shared state:
    #   <root>/
    #     lock              - flock for atomic operations
    #     queue.json        - ordered list of remaining test entries
    #     total             - total test count
    #     master-status     - "ready" once leader has populated
    #     processed/        - files named by test_id (content = worker_id)
    #     error-reports/    - files named by test_id (content = error payload)
    #     requeues.json     - { test_id => count }
    #     worker-errors/    - files named by worker_id (content = error message)
    #
    module Local
      class << self
        def from_uri(uri, config)
          Worker.new(uri.path, config)
        end
      end

      class Worker
        include Common

        CONNECTION_ERRORS = [].freeze

        TEN_MINUTES = 60 * 10
        DEFAULT_SLEEP_SECONDS = 0.1

        attr_accessor :entry_resolver
        attr_reader :config

        def initialize(path, config)
          @root = path
          @config = config
          @shutdown = false
          @progress = 0
          @reserved_tests = []
          @reserved_entries = {}
        end

        def distributed?
          false
        end

        def populate(tests, random: Random.new)
          @index = tests.map { |t| [t.id, t] }.to_h
          entries = tests.map { |test| queue_entry_for(test) }
          push(entries)
          self
        end

        def stream_populate(tests, random: Random.new, batch_size: nil)
          setup!
          entries = []
          tests.each { |test| entries << queue_entry_for(test) }
          entries.shuffle!(random: random)
          with_lock do
            write_json(queue_path, entries)
            ::File.write(total_path, entries.size.to_s)
            ::File.write(status_path, 'ready')
          end
          self
        end

        def populated?
          !!defined?(@index) || (::File.exist?(status_path) && ::File.read(status_path).strip == 'ready')
        end

        def total
          return @total if defined?(@total) && @total
          return 0 unless ::File.exist?(total_path)

          ::File.read(total_path).to_i
        end

        def size
          with_lock { read_queue.size }
        end

        def remaining
          size
        end

        def running
          @reserved_tests.empty? ? 0 : 1
        end

        def progress
          @progress
        end

        def to_a
          entries = with_lock { read_queue }
          if defined?(@index) && @index
            entries.map { |e| @index.fetch(CI::Queue::QueueEntry.test_id(e)) }
          else
            entries
          end
        end

        def exhausted?
          return false unless queue_initialized?

          with_lock { read_queue.empty? }
        end

        def expired?
          if ::File.exist?(created_at_path)
            ts = ::File.read(created_at_path).to_f
            (ts + TEN_MINUTES) < CI::Queue.time_now.to_f
          else
            # No created_at set yet — not expired (mirrors Static behavior)
            false
          end
        end

        def created_at=(timestamp)
          setup!
          ts = timestamp.respond_to?(:to_f) ? timestamp.to_f : timestamp
          with_lock do
            unless ::File.exist?(created_at_path)
              ::File.write(created_at_path, ts.to_s)
            end
          end
        end

        def shutdown!
          @shutdown = true
        end

        def build
          @build ||= LocalBuildRecord.new(self, @root, config)
        end

        def supervisor
          raise NotImplementedError, "Local queues don't need a supervisor — just wait for all worker processes to exit"
        end

        def retry_queue
          failures = build.failed_tests.to_set
          queue = with_lock { read_queue }
          # Try per-worker log first, then fall back to all failures
          log = queue.select { |entry| failures.include?(CI::Queue::QueueEntry.test_id(entry)) }
          log = build.failed_test_entries if log.empty?
          Static.new(log, config)
        end

        def poll
          wait_for_ready
          until @shutdown || config.circuit_breakers.any?(&:open?) || max_test_failed?
            entry = reserve
            break unless entry

            @reserved_tests << entry
            resolved = resolve_entry(entry)
            # Track original entry for requeue
            if resolved.respond_to?(:id)
              @reserved_entries[resolved.id] = entry
            end
            yield resolved
            @reserved_tests.clear
            @reserved_entries.clear
          end
        end

        def acknowledge(entry, error: nil, pipeline: nil)
          test_id = CI::Queue::QueueEntry.test_id(entry)
          with_lock do
            processed = processed_dir
            ::File.write(::File.join(processed, safe_filename(test_id)), worker_id.to_s)
          end
          @progress += 1
          true
        end

        def increment_test_failed(pipeline: nil)
          with_lock do
            count = read_test_failed
            ::File.write(test_failed_path, (count + 1).to_s)
          end
        end

        def test_failed
          with_lock { read_test_failed }
        end

        def max_test_failed?
          return false if config.max_test_failed.nil?

          test_failed >= config.max_test_failed
        end

        def requeue(entry)
          test_id = CI::Queue::QueueEntry.test_id(entry)
          original_entry = @reserved_entries.fetch(test_id, entry)

          with_lock do
            requeues = read_requeues
            count = requeues[test_id] || 0
            total_requeues = requeues.values.inject(0, :+)

            return false unless count < config.max_requeues
            return false unless total_requeues < config.global_max_requeues(total)

            requeues[test_id] = count + 1
            write_requeues(requeues)

            queue = read_queue
            queue.unshift(original_entry)
            write_json(queue_path, queue)
          end
          true
        end

        def release!
          # noop for local
        end

        def with_heartbeat(id, lease: nil)
          yield
        end

        def lease_for(entry)
          nil
        end

        def ensure_heartbeat_thread_alive!; end
        def boot_heartbeat_process!; end
        def stop_heartbeat!; end

        def report_worker_error(error)
          build.report_worker_error(error)
        end

        def queue_initialized?
          ::File.exist?(status_path) && ::File.read(status_path).strip != ''
        end

        def rescue_connection_errors(handler = ->(err) { nil })
          yield
        end

        private

        def worker_id
          config.worker_id || Process.pid.to_s
        end

        def setup!
          FileUtils.mkdir_p(@root)
          FileUtils.mkdir_p(processed_dir)
          FileUtils.mkdir_p(error_reports_dir)
          FileUtils.mkdir_p(worker_errors_dir)
        end

        def push(entries)
          @total = entries.size

          setup!
          with_lock do
            unless ::File.exist?(status_path) && ::File.read(status_path).strip == 'ready'
              write_json(queue_path, entries)
              ::File.write(total_path, @total.to_s)
              ::File.write(status_path, 'ready')
            end
          end
        end

        def reserve
          with_lock do
            queue = read_queue
            return nil if queue.empty?

            entry = queue.shift
            write_json(queue_path, queue)
            entry
          end
        end

        def resolve_entry(entry)
          test_id = CI::Queue::QueueEntry.test_id(entry)

          if entry_resolver
            return entry_resolver.call(entry)
          end

          if defined?(@index) && @index
            return @index[test_id] if @index.key?(test_id)
          end

          entry
        end

        def queue_entry_for(test)
          return test.queue_entry if test.respond_to?(:queue_entry)
          return test.id if test.respond_to?(:id)

          test
        end

        def wait_for_ready(timeout: 30)
          return if queue_initialized?

          (timeout * 10).to_i.times do
            return if queue_initialized?

            sleep 0.1
          end
          raise "Queue was not initialized after #{timeout} seconds"
        end

        # -- File paths --

        def lock_path
          ::File.join(@root, 'lock')
        end

        def queue_path
          ::File.join(@root, 'queue.json')
        end

        def total_path
          ::File.join(@root, 'total')
        end

        def status_path
          ::File.join(@root, 'master-status')
        end

        def created_at_path
          ::File.join(@root, 'created-at')
        end

        def test_failed_path
          ::File.join(@root, 'test-failed-count')
        end

        def requeues_path
          ::File.join(@root, 'requeues.json')
        end

        def processed_dir
          ::File.join(@root, 'processed')
        end

        def error_reports_dir
          ::File.join(@root, 'error-reports')
        end

        def worker_errors_dir
          ::File.join(@root, 'worker-errors')
        end

        # -- Locking --

        def with_lock(&block)
          setup!
          lockfile = ::File.open(lock_path, ::File::CREAT | ::File::RDWR)
          lockfile.flock(::File::LOCK_EX)
          yield
        ensure
          lockfile&.flock(::File::LOCK_UN)
          lockfile&.close
        end

        # -- JSON helpers --

        def read_queue
          return [] unless ::File.exist?(queue_path)

          JSON.parse(::File.read(queue_path))
        rescue JSON::ParserError
          []
        end

        def write_json(path, data)
          ::File.write(path, JSON.generate(data))
        end

        def read_requeues
          return {} unless ::File.exist?(requeues_path)

          JSON.parse(::File.read(requeues_path))
        rescue JSON::ParserError
          {}
        end

        def write_requeues(data)
          write_json(requeues_path, data)
        end

        def read_test_failed
          return 0 unless ::File.exist?(test_failed_path)

          ::File.read(test_failed_path).to_i
        end

        def safe_filename(name)
          name.gsub(/[^a-zA-Z0-9._-]/, '_')
        end
      end

      # File-backed build record, matching the interface of CI::Queue::BuildRecord
      # and CI::Queue::Redis::BuildRecord.
      class LocalBuildRecord
        attr_reader :error_reports

        def initialize(queue, root, config)
          @queue = queue
          @root = root
          @config = config
          @stats = {}
        end

        def progress
          @queue.progress
        end

        def queue_exhausted?
          @queue.exhausted?
        end

        def record_error(entry, payload, stat_delta: nil)
          test_id = CI::Queue::QueueEntry.test_id(entry)
          dir = ::File.join(@root, 'error-reports')
          FileUtils.mkdir_p(dir)
          ::File.write(::File.join(dir, safe_filename(test_id)), payload.to_s)
          @queue.increment_test_failed
          true
        end

        def record_success(entry, skip_flaky_record: false, acknowledge: true)
          test_id = CI::Queue::QueueEntry.test_id(entry)
          path = ::File.join(@root, 'error-reports', safe_filename(test_id))
          ::File.delete(path) if ::File.exist?(path)
          true
        end

        def record_requeue(entry)
          true
        end

        def record_stats(builds_stats)
          return unless builds_stats

          @stats.merge!(builds_stats)
        end

        def record_stats_delta(delta, pipeline: nil)
          return if delta.nil? || delta.empty?

          delta.each do |stat_name, value|
            next unless value.is_a?(Numeric) || value.to_s.match?(/\A-?\d+\.?\d*\z/)

            @stats[stat_name] = (@stats[stat_name] || 0).to_f + value.to_f
          end
        end

        def fetch_stats(stat_names)
          stat_names.zip(@stats.values_at(*stat_names).map(&:to_f)).to_h
        end

        def reset_stats(stat_names)
          stat_names.each { |s| @stats.delete(s) }
        end

        def error_reports
          dir = ::File.join(@root, 'error-reports')
          return {} unless ::File.directory?(dir)

          Dir.children(dir).each_with_object({}) do |name, hash|
            hash[name] = ::File.read(::File.join(dir, name))
          end
        end

        def failed_tests
          error_reports.keys
        end

        def failed_test_entries
          failed_tests
        end

        def report_worker_error(error)
          dir = ::File.join(@root, 'worker-errors')
          FileUtils.mkdir_p(dir)
          wid = @config.worker_id || Process.pid.to_s
          ::File.write(::File.join(dir, safe_filename(wid)), error.message)
        end

        def reset_worker_error
          wid = @config.worker_id || Process.pid.to_s
          path = ::File.join(@root, 'worker-errors', safe_filename(wid))
          ::File.delete(path) if ::File.exist?(path)
        end

        def worker_errors
          dir = ::File.join(@root, 'worker-errors')
          return {} unless ::File.directory?(dir)

          Dir.children(dir).each_with_object({}) do |name, hash|
            hash[name] = ::File.read(::File.join(dir, name))
          end
        end

        private

        def safe_filename(name)
          name.to_s.gsub(/[^a-zA-Z0-9._-]/, '_')
        end
      end
    end
  end
end
