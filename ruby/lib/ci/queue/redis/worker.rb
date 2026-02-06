# frozen_string_literal: true
require 'ci/queue/static'
require 'ci/queue/lazy_loader'
require 'concurrent/set'

module CI
  module Queue
    module Redis
      class << self
        attr_accessor :requeue_offset
        attr_accessor :max_sleep_time
      end
      self.requeue_offset = 42
      self.max_sleep_time = 2

      # Wrapper for lazy loading queue entries that mimics a test object
      # This allows shufflers and other code to treat "path\ttest_id" strings
      # as if they were test objects with an .id method
      class LazyTestEntry
        attr_reader :entry

        def initialize(entry)
          @entry = entry
        end

        # Extract test_id from "file_path\ttest_id" format
        def id
          @id ||= entry.split("\t", 2).last
        end

        # Comparison operator for sorting/shuffling
        def <=>(other)
          id <=> other.id
        end

        # Return the original string format for queue storage
        def to_s
          entry
        end
      end

      class Worker < Base
        def initialize(redis, config)
          @reserved_tests = Concurrent::Set.new
          @shutdown_required = false
          @lazy_loader = LazyLoader.new if config.lazy_load?
          super(redis, config)
        end

        def distributed?
          true
        end

        # Fetch total test count, either from instance variable (if leader)
        # or from Redis (if non-leader worker).
        # In streaming mode, total may not be finalized yet, so we avoid
        # caching a zero value.
        def total
          return @total if @total && @total > 0

          @total = begin
            wait_for_master(timeout: config.queue_init_timeout)
            redis.get(key('total')).to_i
          end
        end

        def populate(tests, random: Random.new)
          @index = tests.map { |t| [t.id, t] }.to_h
          tests = Queue.shuffle(tests, random)
          push(tests.map(&:id))
          self
        end

        # Populate queue with lazy loading support (streaming mode)
        # Tests are pushed to the queue as each file is loaded, allowing workers
        # to start claiming tests before all files are loaded.
        #
        # Queue entry format: "file_path\ttest_id"
        # This embeds the file path so workers can load files on-demand without
        # waiting for a manifest.
        #
        # file_loader: a callable that takes a file_path and returns an array of
        #   objects responding to #id (the test identifier string).
        # test_factory: a callable that takes (class_name, method_name, file_path)
        #   and returns a test example object suitable for yielding from poll.
        def populate_lazy(test_files:, random:, config:, file_loader:, test_factory:)
          @lazy_load_mode = true
          @lazy_loader ||= LazyLoader.new
          @test_factory = test_factory

          push_streaming(test_files: test_files, random: random, config: config, file_loader: file_loader)
          self
        end

        def populated?
          !!defined?(@index) || @lazy_load_mode
        end

        def lazy_load?
          @lazy_load_mode || config.lazy_load?
        end

        # Override base exhausted? to handle streaming mode.
        # During streaming, the leader pushes tests incrementally. The queue may
        # be temporarily empty between batches. Without this check, consumers
        # would exit the poll loop thinking the queue is done.
        def exhausted?
          return false if @lazy_load_mode && !streaming_complete?

          super
        end

        def files_loaded_count
          return 0 unless @lazy_loader

          @lazy_loader.files_loaded_count
        end

        def shutdown!
          @shutdown_required = true
        end

        def shutdown_required?
          @shutdown_required
        end

        def master?
          @master
        end

        DEFAULT_SLEEP_SECONDS = 0.5

        def poll
          wait_for_master
          attempt = 0
          until shutdown_required? || config.circuit_breakers.any?(&:open?) || exhausted? || max_test_failed?
            if test_id = reserve_entry
              attempt = 0
              # Use @index if available (eager mode), otherwise load on-demand (lazy mode)
              example = if index
                index.fetch(test_id)
              else
                load_test_from_entry(test_id)
              end
              yield example
            else
              # Adding exponential backoff to avoid hammering Redis
              # we just stay online here in case a test gets retried or times out so we can afford to wait
              sleep_time = [DEFAULT_SLEEP_SECONDS * (2 ** attempt), Redis.max_sleep_time].min
              attempt += 1
              sleep sleep_time
            end
          end
          redis.pipelined do |pipeline|
            pipeline.expire(key('worker', worker_id, 'queue'), config.redis_ttl)
            pipeline.expire(key('processed'), config.redis_ttl)
          end
        rescue *CONNECTION_ERRORS
        end

        # Parse a queue entry which may be in one of two formats:
        # - Plain test ID: "ClassName#test_method"
        # - Tab-separated with file path: "file_path.rb\tClassName#test_method"
        def parse_queue_entry(entry)
          if entry.include?("\t")
            file_path, test_id = entry.split("\t", 2)
            [file_path, test_id]
          else
            [nil, entry]
          end
        end

        # Reserve a test entry
        # - Stores the full queue_entry in reserved_tests (for Redis operations)
        # - Returns the test_id (for test loading and matching with test.id)
        # - Maintains mapping from test_id to queue_entry for acknowledge/requeue
        def reserve_entry
          queue_entry = try_to_reserve_lost_test || try_to_reserve_test
          return nil unless queue_entry

          file_path, test_id = parse_queue_entry(queue_entry)

          # Track the full queue_entry for Redis operations
          reserved_tests << queue_entry

          # Unified storage: single source of truth per test
          @pending_tests ||= {}
          @pending_tests[test_id] = {
            entry: queue_entry,
            file: file_path
          }

          test_id
        end

        # Get the queue entry for a test_id (used by acknowledge/requeue).
        # In streaming mode, reserved_tests contains "file_path\ttest_id" entries.
        # If @pending_tests doesn't have a mapping (e.g., after requeue consumed it),
        # scan reserved_tests for a matching suffix.
        def queue_entry_for_test(test_id)
          @pending_tests ||= {}
          pending = @pending_tests[test_id]
          return pending[:entry] if pending

          # Fallback: find the matching entry in reserved_tests by test_id suffix.
          # This handles cases where @pending_tests lost the mapping (e.g., requeue
          # path consumed it, or acknowledge is called from a different context like DRb).
          match = reserved_tests.find { |entry| parse_queue_entry(entry).last == test_id }
          match || test_id
        end

        # Load a test from a queue entry using the embedded file path or manifest
        def load_test_from_entry(test_id)
          class_name, method_name = LazyLoader.parse_test_id(test_id)

          # Get file path from unified pending tests structure
          @pending_tests ||= {}
          pending = @pending_tests[test_id]
          file_path = pending[:file] if pending

          if file_path
            # Streaming mode: load file directly
            @lazy_loader.load_file_directly(file_path)
          else
            # Legacy mode: use manifest
            fetch_manifest_for_lazy_load
            @lazy_loader.load_class(class_name)
          end

          runnable = @lazy_loader.find_class(class_name)

          # Trigger runnable_methods to ensure dynamically generated test methods exist
          if runnable.respond_to?(:runnable_methods)
            runnable.runnable_methods
          end

          @test_factory.call(class_name, method_name, file_path)
        end

        def fetch_manifest_for_lazy_load
          return unless @lazy_loader
          return if @manifest_fetched

          @lazy_loader.fetch_manifest(redis, key('manifest'))
          @manifest_fetched = true
        end

        if ::Redis.method_defined?(:exists?)
          def retrying?
            redis.exists?(key('worker', worker_id, 'queue'))
          rescue *CONNECTION_ERRORS
            false
          end
        else
          def retrying?
            redis.exists(key('worker', worker_id, 'queue'))
          rescue *CONNECTION_ERRORS
            false
          end
        end

        def retry_queue
          failures = build.failed_tests.to_set
          log = redis.lrange(key('worker', worker_id, 'queue'), 0, -1)
          # Worker queue stores full entries ("file_path\ttest_id" in streaming mode).
          # failed_tests returns plain test_ids (from error-reports). Extract test_id
          # for comparison but keep the full entry for the retry queue.
          log.select! { |entry| failures.include?(parse_queue_entry(entry).last) }
          log.uniq!
          log.reverse!
          Retry.new(log, config, redis: redis)
        end

        def supervisor
          Supervisor.new(redis_url, config)
        end

        def build
          @build ||= CI::Queue::Redis::BuildRecord.new(self, redis, config)
        end

        def report_worker_error(error)
          build.report_worker_error(error)
        end

        def acknowledge(test_key, error: nil, pipeline: redis)
          # Convert test_id to full queue entry (may include file path in streaming mode)
          queue_entry = queue_entry_for_test(test_key)
          raise_on_mismatching_test(queue_entry, test_key)
          eval_script(
            :acknowledge,
            keys: [key('running'), key('processed'), key('owners'), key('error-reports')],
            argv: [queue_entry, error.to_s, config.redis_ttl],
            pipeline: pipeline,
          ) == 1
        end

        def requeue(test, offset: Redis.requeue_offset)
          test_key = test.id
          # Convert test_id to full queue entry (may include file path in streaming mode)
          queue_entry = queue_entry_for_test(test_key)
          raise_on_mismatching_test(queue_entry, test_key)
          global_max_requeues = config.global_max_requeues(total)

          requeued = config.max_requeues > 0 && global_max_requeues > 0 && eval_script(
            :requeue,
            keys: [
              key('processed'),
              key('requeues-count'),
              key('queue'),
              key('running'),
              key('worker', worker_id, 'queue'),
              key('owners'),
              key('error-reports'),
            ],
            argv: [config.max_requeues, global_max_requeues, queue_entry, offset],
          ) == 1

          reserved_tests << queue_entry unless requeued
          requeued
        end

        def release!
          eval_script(
            :release,
            keys: [key('running'), key('worker', worker_id, 'queue'), key('owners')],
            argv: [],
          )
          nil
        end

        private

        attr_reader :index

        # Check if the leader has finished pushing all tests in streaming mode.
        # Memoize true (streaming complete is permanent) but re-check Redis if false.
        def streaming_complete?
          return true if @streaming_complete

          @streaming_complete = redis.get(key('streaming-complete')) == '1'
        end

        # Debug output helper - only prints if CI_QUEUE_DEBUG is set
        def debug_puts(message)
          puts message if ENV['CI_QUEUE_DEBUG']
        end

        def reserved_tests
          @reserved_tests ||= Concurrent::Set.new
        end

        def worker_id
          config.worker_id
        end

        def raise_on_mismatching_test(queue_entry, test_key = nil)
          unless reserved_tests.delete?(queue_entry)
            display_key = test_key || queue_entry
            raise ReservationError, "Acknowledged #{display_key.inspect} but only #{reserved_tests.map(&:inspect).join(", ")} reserved"
          end
        end

        def reserve
          (try_to_reserve_lost_test || try_to_reserve_test).tap do |test|
            reserved_tests << test if test
          end
        end

        def try_to_reserve_test
          eval_script(
            :reserve,
            keys: [
              key('queue'),
              key('running'),
              key('processed'),
              key('worker', worker_id, 'queue'),
              key('owners'),
            ],
            argv: [CI::Queue.time_now.to_f],
          )
        end

        def try_to_reserve_lost_test
          timeout = config.max_missed_heartbeat_seconds ? config.max_missed_heartbeat_seconds : config.timeout

          lost_test = eval_script(
            :reserve_lost,
            keys: [
              key('running'),
              key('completed'),
              key('worker', worker_id, 'queue'),
              key('owners'),
            ],
            argv: [CI::Queue.time_now.to_f, timeout],
          )

          if lost_test
            build.record_warning(Warnings::RESERVED_LOST_TEST, test: lost_test, timeout: config.timeout)
          end

          lost_test
        end

        # Push test IDs to the queue.
        # Can be called with test IDs directly, or with a block that returns test IDs.
        # The block form is used for lazy loading where only the master loads test files.
        def push(tests = nil, &block)
          @total = tests.size if tests

          # We set a unique value (worker_id) and read it back to make "SET if Not eXists" idempotent in case of a retry.
          value = key('setup', worker_id)
          _, status = redis.pipelined do |pipeline|
            pipeline.set(key('master-status'), value, nx: true)
            pipeline.get(key('master-status'))
          end

          if @master = (value == status)
            # If block given, call it to get test IDs (used for lazy loading)
            tests = yield if block_given?
            @total = tests.size

            puts "Worker elected as leader, pushing #{@total} tests to the queue."
            puts

            attempts = 0
            duration = measure do
              with_redis_timeout(5) do
                redis.without_reconnect do
                  redis.multi do |transaction|
                    transaction.lpush(key('queue'), tests) unless tests.empty?
                    transaction.set(key('total'), @total)
                    transaction.set(key('master-status'), 'ready')

                    transaction.expire(key('queue'), config.redis_ttl)
                    transaction.expire(key('total'), config.redis_ttl)
                    transaction.expire(key('master-status'), config.redis_ttl)
                  end
                end
              rescue ::Redis::BaseError => error
                if !queue_initialized? && attempts < 3
                  puts "Retrying pushing #{@total} tests to the queue... (#{error})"
                  attempts += 1
                  retry
                end

                raise if !queue_initialized?
              end
            end

            puts "Finished pushing #{@total} tests to the queue in #{duration.round(2)}s."
          end
          register
          redis.expire(key('workers'), config.redis_ttl)
        rescue *CONNECTION_ERRORS
          raise if @master
        end

        # Streaming queue population for lazy loading.
        # Unlike push(), this method:
        # 1. Loads test files one at a time via the file_loader callback
        # 2. Pushes tests to queue immediately after loading each file
        # 3. Sets master-status to 'ready' early so workers can start
        # 4. Uses queue entries with embedded file path: "file_path\ttest_id"
        def push_streaming(test_files:, random:, config:, file_loader:)
          debug_puts "[ci-queue] push_streaming called with #{test_files.size} test files"

          # Leader election - same as push()
          value = key('setup', worker_id)
          _, status = redis.pipelined do |pipeline|
            pipeline.set(key('master-status'), value, nx: true)
            pipeline.get(key('master-status'))
          end

          if @master = (value == status)
            debug_puts "[ci-queue] Worker #{worker_id} elected as LEADER"
            push_streaming_as_leader(test_files: test_files, random: random, config: config, file_loader: file_loader)
          else
            debug_puts "[ci-queue] Worker #{worker_id} is CONSUMER, waiting for leader (status=#{status.inspect})"
            # Not the leader - wait for queue to be initialized
            wait_for_streaming_queue(config: config)
          end

          register
          redis.expire(key('workers'), config.redis_ttl)
        rescue *CONNECTION_ERRORS
          raise if @master
        end

        def push_streaming_as_leader(test_files:, random:, config:, file_loader:)
          all_tests = []
          files_loaded = 0
          total_pushed = 0
          queue_initialized = false
          start_time = CI::Queue.time_now

          debug_puts "[ci-queue] Leader starting to load #{test_files.size} test files..."

          begin
            # Load each test file and push tests IMMEDIATELY
            # This ensures workers can start as soon as possible
            test_files.each do |file_path|
              begin
                # Use the file_loader callback to load a file and discover tests.
                # Returns an array of objects responding to #id.
                new_tests = file_loader.call(file_path)
                all_tests.concat(new_tests)

                # Track that this file was loaded so load_file_directly
                # won't re-execute it when the leader polls its own tests.
                @lazy_loader.loaded_files.add(file_path)

                file_entries = new_tests.map { |test| "#{file_path}\t#{test.id}" }

                files_loaded += 1

                # Push this file's tests immediately (allows workers to start ASAP)
                if file_entries.any?
                  # Shuffle entries from this file
                  wrapped_entries = file_entries.map { |entry| LazyTestEntry.new(entry) }
                  shuffled_wrapped = Queue.shuffle(wrapped_entries, random)
                  shuffled_entries = shuffled_wrapped.map(&:to_s)

                  if !queue_initialized
                    elapsed = (CI::Queue.time_now - start_time).round(2)
                    debug_puts "[ci-queue] First file with tests loaded after #{elapsed}s, initializing queue with #{shuffled_entries.size} tests..."

                    redis.multi do |transaction|
                      transaction.lpush(key('queue'), shuffled_entries)
                      transaction.set(key('master-status'), 'ready')

                      transaction.expire(key('queue'), config.redis_ttl)
                      transaction.expire(key('master-status'), config.redis_ttl)
                    end
                    queue_initialized = true
                    debug_puts "[ci-queue] Queue initialized, master-status set to 'ready'"
                  else
                    # Subsequent files: just push to queue
                    redis.lpush(key('queue'), shuffled_entries)
                  end

                  total_pushed += shuffled_entries.size

                  # Progress update every 100 files
                  if files_loaded % 100 == 0
                    elapsed = (CI::Queue.time_now - start_time).round(2)
                    debug_puts "[ci-queue] Progress: #{files_loaded}/#{test_files.size} files, #{total_pushed} tests pushed (#{elapsed}s elapsed)"
                  end
                end
              rescue LoadError => e
                raise LazyLoadError, "Failed to load test file #{file_path}: #{e.message}"
              end
            end

            if total_pushed == 0
              raise LazyLoadError, "No tests found after loading #{test_files.size} test files."
            end

            @files_loaded_by_leader = files_loaded
            @total = total_pushed

            # Set the total count and mark streaming as complete.
            # total is only set once all files are loaded to avoid consumers
            # memoizing a partial count. streaming-complete signals that the
            # queue will not receive more tests, so exhausted? can return true.
            redis.multi do |transaction|
              transaction.set(key('total'), @total)
              transaction.set(key('streaming-complete'), '1')
              transaction.expire(key('total'), config.redis_ttl)
              transaction.expire(key('streaming-complete'), config.redis_ttl)
            end
            @streaming_complete = true

            elapsed = (CI::Queue.time_now - start_time).round(2)
            debug_puts "[ci-queue] Leader finished: #{files_loaded} files, #{@total} tests in #{elapsed}s"

            # Build and store manifest for backward compatibility
            manifest = LazyLoader.build_manifest(all_tests)
            @lazy_loader.set_manifest(manifest)
            @lazy_loader.store_manifest(redis, key('manifest'), manifest, ttl: config.redis_ttl)

            puts "Leader loaded #{files_loaded} test files, found #{@total} tests."

          rescue LazyLoadError
            raise
          rescue => error
            build.report_worker_error(error)
            raise LazyLoadError, "Failed during streaming population: #{error.class}: #{error.message}"
          end
        end

        def wait_for_streaming_queue(config:)
          # Use configured timeout, default to 5 minutes for large test suites
          timeout = config.queue_init_timeout || 300
          deadline = CI::Queue.time_now + timeout
          last_status_log = CI::Queue.time_now

          debug_puts "[ci-queue] Consumer waiting for queue (timeout=#{timeout}s)..."

          until queue_initialized?
            if CI::Queue.time_now > deadline
              status = redis.get(key('master-status'))
              raise LostMaster, "Queue not initialized after #{timeout} seconds waiting for leader. master-status=#{status.inspect}"
            end

            # Log status every 10 seconds
            if CI::Queue.time_now - last_status_log >= 10
              status = redis.get(key('master-status'))
              elapsed = (CI::Queue.time_now - (deadline - timeout)).round(1)
              debug_puts "[ci-queue] Still waiting for queue... (#{elapsed}s elapsed, master-status=#{status.inspect})"
              last_status_log = CI::Queue.time_now
            end

            sleep 0.1
          end

          debug_puts "[ci-queue] Queue ready, consumer can start"
        end

        def register
          redis.sadd(key('workers'), [worker_id])
        end
      end
    end
  end
end
