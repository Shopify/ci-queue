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

      class Worker < Base
        attr_reader :total

        def initialize(redis, config)
          @reserved_tests = Concurrent::Set.new
          @shutdown_required = false
          @lazy_loader = LazyLoader.new if config.lazy_load?
          super(redis, config)
        end

        def distributed?
          true
        end

        def populate(tests, random: Random.new)
          @index = tests.map { |t| [t.id, t] }.to_h
          tests = Queue.shuffle(tests, random)
          push(tests.map(&:id))
          self
        end

        # Populate queue with lazy loading support
        # Only the leader loads all test files and builds the manifest
        # Workers load files on-demand when they claim tests
        def populate_lazy(test_files:, random:, config:)
          @lazy_load_mode = true
          @lazy_loader ||= LazyLoader.new

          push do
            begin
              # This block only runs on master - load files and build manifest
              test_files.each do |f|
                require(f)
              rescue LoadError => e
                raise LazyLoadError, "Failed to load test file #{f}: #{e.message}"
              end

              tests = Minitest.loaded_tests
              if tests.empty?
                raise LazyLoadError, "No tests found after loading #{test_files.size} test files. " \
                                     "Ensure test files define Minitest::Test subclasses."
              end

              # Build and store manifest
              manifest = LazyLoader.build_manifest(tests)
              @lazy_loader.set_manifest(manifest)
              @lazy_loader.store_manifest(redis, key('manifest'), manifest, ttl: config.redis_ttl)

              # Count files loaded for metrics
              source_files = Set.new
              tests.each do |test|
                source_location = test.source_location&.first
                source_files.add(source_location) if source_location
              end
              @files_loaded_by_leader = source_files.size

              puts "Leader loaded #{@files_loaded_by_leader} test files, found #{tests.size} tests."

              # Return shuffled test IDs
              Queue.shuffle(tests, random).map(&:id)
            rescue LazyLoadError
              raise
            rescue => error
              build.report_worker_error(error)
              raise LazyLoadError, "Failed to build manifest: #{error.class}: #{error.message}"
            end
          end
          self
        end

        def populated?
          !!defined?(@index) || @lazy_load_mode
        end

        def lazy_load?
          @lazy_load_mode || config.lazy_load?
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
          fetch_manifest_for_lazy_load if lazy_load?
          attempt = 0
          until shutdown_required? || config.circuit_breakers.any?(&:open?) || exhausted? || max_test_failed?
            if test_id = reserve
              attempt = 0
              example = lazy_load? ? load_test_lazily(test_id) : index.fetch(test_id)
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

        def fetch_manifest_for_lazy_load
          return unless @lazy_loader
          return if @manifest_fetched

          @lazy_loader.fetch_manifest(redis, key('manifest'))
          @manifest_fetched = true
        end

        def load_test_lazily(test_id)
          class_name, method_name = LazyLoader.parse_test_id(test_id)
          @lazy_loader.load_class(class_name)
          # Return a SingleExample like the index would
          runnable = @lazy_loader.find_class(class_name)
          Minitest::Queue::SingleExample.new(runnable, method_name)
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

        def reserved_tests
          @reserved_tests ||= Concurrent::Set.new
        end

        def worker_id
          config.worker_id
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

        def register
          redis.sadd(key('workers'), [worker_id])
        end
      end
    end
  end
end
