# frozen_string_literal: true
require 'ci/queue/static'
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

      class Worker < Base
        attr_reader :total

        def initialize(redis, config)
          @reserved_tests = Concurrent::Set.new
          @shutdown_required = false
          super(redis, config)
        end

        def distributed?
          true
        end

        def populate(tests, random: Random.new)
          if config.batch_upload
            @index = {}
            @source_files_loaded = Set.new
          else
            @index = tests.map { |t| [t.id, t] }.to_h
          end
          tests = Queue.shuffle(tests, random)
          push(tests.map(&:id))
          self
        end

        def populate_from_files(file_paths, random: Random.new)
          @file_paths = file_paths.sort
          @index = {}
          @source_files_loaded = Set.new
          push_files_in_batches(@file_paths, random)
          self
        end

        def populated?
          !!defined?(@index)
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
          # Non-master workers need to fetch total from Redis after master finishes
          @total ||= redis.get(key('total')).to_i unless master?
          puts "Starting poll loop, master: #{master?}"
          attempt = 0
          until shutdown_required? || config.circuit_breakers.any?(&:open?) || exhausted? || max_test_failed?
            if test_id = reserve
              attempt = 0

              # Lazy load test if needed (batch mode)
              test = if config.batch_upload && !@index.key?(test_id)
                @index[test_id] = build_index_entry(test_id)
              else
                index.fetch(test_id)
              end

              yield test
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
          log.select! { |id| failures.include?(id) }
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
          raise_on_mismatching_test(test_key)
          eval_script(
            :acknowledge,
            keys: [key('running'), key('processed'), key('owners'), key('error-reports')],
            argv: [test_key, error.to_s, config.redis_ttl],
            pipeline: pipeline,
          ) == 1
        end

        def requeue(test, offset: Redis.requeue_offset)
          test_key = test.id
          raise_on_mismatching_test(test_key)
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
            argv: [config.max_requeues, global_max_requeues, test_key, offset],
          ) == 1

          reserved_tests << test_key unless requeued
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

        def push_files_in_batches(file_paths, random)
          #Elect master (existing logic)
          value = key('setup', worker_id)
          _, status = redis.pipelined do |pipeline|
            pipeline.set(key('master-status'), value, nx: true)
            pipeline.get(key('master-status'))
          end

          if @master = (value == status)
            puts "Worker elected as leader, loading and pushing tests in batches..."
            puts

            # Set status to 'streaming' to signal workers can start
            redis.set(key('master-status'), 'streaming')

            # Group files into batches based on batch_size
            # Since we're batching by files, calculate files per batch to approximate tests per batch
            files_per_batch = [config.batch_size / 10, 1].max # Estimate ~10 tests per file

            all_tests = []
            tests_uploaded = 0

            attempts = 0
            duration = measure do
              file_paths.each_slice(files_per_batch).with_index do |file_batch, batch_num|
                puts "Processing batch #{batch_num} with #{file_batch.size} files..."
                # Track which file loaded which runnables
                runnable_to_file = {}

                # Load all files in this batch
                file_batch.each do |file_path|
                  abs_path = ::File.expand_path(file_path)
                  puts "Loading file #{abs_path}..."
                  require abs_path
                  puts "Finished loading file #{abs_path}..."
                  @source_files_loaded.add(abs_path)
                end

                # Extract tests from runnables (call runnables only once!)
                # The @index.key? check automatically skips already-processed tests
                batch_tests = []
                if defined?(Minitest)
                  puts "Extracting tests from runnables..."
                  Minitest::Test.runnables.each do |runnable|
                    runnable.runnable_methods.each do |method_name|
                      test = Minitest::Queue::SingleExample.new(runnable, method_name)
                      unless @index.key?(test.id)
                        batch_tests << test
                        @index[test.id] = test
                        # Map this runnable to the batch file for metadata
                        runnable_to_file[runnable] ||= file_batch.first
                      end
                    end
                  end
                end

                puts "Found #{batch_tests.size} new tests in batch"

                # Shuffle tests in this batch
                batch_tests = Queue.shuffle(batch_tests, random)
                puts "Shuffled tests: #{batch_tests.size}"
                unless batch_tests.empty?
                  # Extract metadata
                  test_ids = []
                  metadata = {}

                  batch_tests.each do |test|
                    test_ids << test.id
                    # Use the file that loaded the runnable, not source_location
                    if runnable_to_file.key?(test.runnable)
                      metadata[test.id] = runnable_to_file[test.runnable]
                    elsif test.respond_to?(:source_location) && (location = test.source_location)
                      metadata[test.id] = location[0] # fallback to source_location
                    end
                  end

                  # Upload batch to Redis
                  puts "Uploading batch to Redis..."
                  with_redis_timeout(5) do
                    redis.without_reconnect do
                      redis.pipelined do |pipeline|
                        pipeline.lpush(key('queue'), test_ids)
                        pipeline.mapped_hmset(key('test-metadata'), metadata) unless metadata.empty?
                        pipeline.incr(key('batch-count'))
                        pipeline.expire(key('queue'), config.redis_ttl)
                        pipeline.expire(key('test-metadata'), config.redis_ttl)
                        pipeline.expire(key('batch-count'), config.redis_ttl)
                      end
                    end
                  rescue ::Redis::BaseError => error
                    if attempts < 3
                      puts "Retrying batch upload... (#{error})"
                      attempts += 1
                      retry
                    end
                    raise
                  end

                  puts "Finished uploading batch to Redis..."

                  tests_uploaded += test_ids.size

                  # Progress reporting
                  if (batch_num + 1) % 10 == 0 || batch_num == 0
                    puts "Uploaded #{tests_uploaded} tests from #{(batch_num + 1) * files_per_batch} files..."
                  end
                end

                all_tests.concat(batch_tests)
              end
            end

            @total = all_tests.size

            # Mark upload complete
            redis.multi do |transaction|
              transaction.set(key('total'), @total)
              transaction.set(key('master-status'), 'ready')
              transaction.expire(key('total'), config.redis_ttl)
              transaction.expire(key('master-status'), config.redis_ttl)
            end

            puts
            puts "Finished pushing #{@total} tests to the queue in #{duration.round(2)}s."
          else
            # Non-master workers need to load at least one test file to ensure
            # the test_helper (and thus minitest/autorun) is loaded, which registers
            # the at_exit hook needed for test execution
            unless file_paths.empty?
              first_file = file_paths.first
              abs_path = ::File.expand_path(first_file)
              require abs_path
              @source_files_loaded.add(abs_path)
            end
          end

          register
          redis.expire(key('workers'), config.redis_ttl)
        rescue *CONNECTION_ERRORS
          raise if @master
        end

        def reserved_tests
          @reserved_tests ||= Concurrent::Set.new
        end

        def worker_id
          config.worker_id
        end

        def build_index_entry(test_id)
          # Try to load from metadata
          file_path = redis.hget(key('test-metadata'), test_id)

          if file_path && !@source_files_loaded.include?(file_path)
            puts "Loading test file #{file_path}..."
            # Lazy load the test file
            require_test_file(file_path)
            @source_files_loaded.add(file_path)
          end

          # Find the test in loaded runnables
          find_test_object(test_id)
        end

        def require_test_file(file_path)
          # Make path absolute if needed
          abs_path = if file_path.start_with?('/')
            file_path
          else
            ::File.expand_path(file_path)
          end

          # Require the file
          require abs_path
        rescue LoadError => e
          # Log warning but continue
          warn "Warning: Could not load test file #{file_path}: #{e.message}"
        end

        def find_test_object(test_id)
          # For Minitest
          if defined?(Minitest)
            Minitest::Test.runnables.each do |runnable|
              runnable.runnable_methods.each do |method_name|
                candidate_id = "#{runnable}##{method_name}"
                if candidate_id == test_id
                  return Minitest::Queue::SingleExample.new(runnable, method_name)
                end
              end
            end
          end

          # Fallback: create a test object that will report an error
          puts "Warning: Test #{test_id} not found after loading file. Ensure all dependencies are explicitly required in test_helper.rb"
          # Return nil and let index.fetch handle the KeyError
          nil
        end

        def raise_on_mismatching_test(test)
          unless reserved_tests.delete?(test)
            raise ReservationError, "Acknowledged #{test.inspect} but only #{reserved_tests.map(&:inspect).join(", ")} reserved"
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

        def push(tests)
          @total = tests.size

          # We set a unique value (worker_id) and read it back to make "SET if Not eXists" idempotent in case of a retry.
          value = key('setup', worker_id)
          _, status = redis.pipelined do |pipeline|
            pipeline.set(key('master-status'), value, nx: true)
            pipeline.get(key('master-status'))
          end

          if @master = (value == status)
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

        def register
          redis.sadd(key('workers'), [worker_id])
        end
      end
    end
  end
end
