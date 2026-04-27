# frozen_string_literal: true
require 'ci/queue/static'
require 'concurrent/set'
require 'concurrent/map'

module CI
  module Queue
    module Redis
      class << self
        attr_accessor :requeue_offset
        attr_accessor :max_sleep_time
      end
      self.requeue_offset = 42
      self.max_sleep_time = 2

      # Minimal wrapper returned by resolve_entry when neither @index nor entry_resolver
      # is available. Provides the interface callers expect (.id, .queue_entry) so that
      # downstream code doesn't crash with NoMethodError on a raw String.
      UnresolvedEntry = Struct.new(:id, :queue_entry)

      # Describes the current reservation context yielded out of `poll`.
      # Callers in file-affinity mode use this to learn whether the example
      # they are running came from a per-test reservation or from inside a
      # file reservation.
      Reservation = Struct.new(:type, :entry, :lease, keyword_init: true) do
        def file?
          type == :file
        end

        def test?
          type == :test
        end
      end

      class Worker < Base
        attr_accessor :entry_resolver
        attr_reader :first_reserve_at

        def initialize(redis, config)
          @reserved_tests = Concurrent::Set.new
          @reserved_leases = Concurrent::Map.new
          @shutdown_required = false
          @first_reserve_at = nil
          super(redis, config)
        end

        def distributed?
          true
        end

        def populate(tests, random: Random.new)
          @index = tests.map { |t| [t.id, t] }.to_h
          entries = Queue.shuffle(tests, random).map { |test| queue_entry_for(test) }
          push(entries)
          self
        end

        def stream_populate(tests, random: Random.new, batch_size: 10_000)
          batch_size = batch_size.to_i
          batch_size = 1 if batch_size < 1

          value = key('setup', worker_id)
          _, status = redis.pipelined do |pipeline|
            pipeline.set(key('master-status'), value, nx: true)
            pipeline.get(key('master-status'))
          end

          if @master = (value == status)
            @total = 0
            puts "Worker elected as leader, streaming tests to the queue."

            duration = measure do
              start_streaming!
              buffer = []

              tests.each do |test|
                buffer << test

                if buffer.size >= batch_size
                  push_batch(buffer, random)
                  buffer.clear
                end
              end

              push_batch(buffer, random) unless buffer.empty?
              finalize_streaming
            end

            puts "Streamed #{@total} tests in #{duration.round(2)}s."
            $stdout.flush
          end

          register
          redis.expire(key('workers'), config.redis_ttl)
          self
        rescue *CONNECTION_ERRORS
          raise if @master
        end

        def populated?
          !!defined?(@index)
        end

        def total
          return @total if defined?(@total) && @total

          redis.get(key('total')).to_i
        rescue *CONNECTION_ERRORS
          @total || 0
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

        def poll(&block)
          wait_for_master(timeout: config.queue_init_timeout, allow_streaming: true)
          attempt = 0
          until shutdown_required? || config.circuit_breakers.any?(&:open?) || exhausted? || max_test_failed?
            if entry = reserve
              attempt = 0
              if CI::Queue::QueueEntry.file_entry?(entry)
                process_file_entry(entry, &block)
              else
                reservation = Reservation.new(type: :test, entry: entry, lease: lease_for(entry))
                yield_reservation(resolve_entry(entry), reservation, &block)
              end
            else
              if still_streaming?
                raise LostMaster, "Streaming stalled for more than #{config.lazy_load_streaming_timeout}s" if streaming_stale?
                sleep 0.1
                next
              end
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
          # Keep full entries (test_id + file_path) so lazy loading can resolve them.
          # Filter by test_id against failures without stripping file paths.
          log.select! { |entry| failures.include?(CI::Queue::QueueEntry.test_id(entry)) }
          log.uniq! { |entry| CI::Queue::QueueEntry.test_id(entry) }
          log.reverse!

          if log.empty?
            # Per-worker log has no matching failures — this worker didn't run
            # the failing tests (e.g. Buildkite rebuild with new worker IDs,
            # or a different parallel slot). Fall back to ALL unresolved
            # failures from error-reports so any worker can retry them.
            log = redis.hkeys(key('error-reports'))
          end

          Retry.new(log, config, redis: redis)
        end

        def supervisor
          Supervisor.new(redis_url, config)
        end

        def build
          @build ||= CI::Queue::Redis::BuildRecord.new(self, redis, config)
        end

        def file_loader
          @file_loader ||= CI::Queue::FileLoader.new
        end

        def worker_queue_length
          redis.llen(key('worker', worker_id, 'queue'))
        rescue *CONNECTION_ERRORS
          nil
        end

        def lease_for(entry)
          @reserved_leases[CI::Queue::QueueEntry.reservation_key(entry)]
        end

        # Reservation context for the work unit currently being yielded out
        # of poll. Set by `process_file_entry` while it iterates examples
        # inside a file; nil otherwise. Used by `Minitest::Queue.run` to
        # heartbeat against the file's lease.
        attr_reader :current_reservation

        def current_reservation_entry
          @current_reservation&.entry
        end

        def current_reservation_lease
          @current_reservation&.lease
        end

        # File-affinity worker-profile accessors. Read by `store_worker_profile`
        # to surface per-worker file-affinity metrics. Empty/zero in non-
        # file-affinity mode.
        def file_affinity_files_run
          @file_affinity_files_run ||= 0
        end

        def file_affinity_per_file_timings
          @file_affinity_per_file_timings ||= []
        end

        # Top-N slowest files this worker processed, sorted descending by
        # wall-clock duration. Surfaced in WorkerProfileReporter when debug
        # is enabled. N defaults to 10; the supervisor aggregates across
        # workers to compute global P50/P95/P99.
        def file_affinity_slowest_files(limit: 10)
          (@file_affinity_slow_files || []).first(limit)
        end

        def report_worker_error(error)
          build.report_worker_error(error)
        end

        def acknowledge(entry, error: nil, pipeline: redis)
          reservation = CI::Queue::QueueEntry.reservation_key(entry)
          assert_reserved!(reservation)
          entry = reserved_entries.fetch(reservation, entry)
          lease = @reserved_leases.delete(reservation)
          unreserve_entry(reservation)
          eval_script(
            :acknowledge,
            keys: [key('running'), key('processed'), key('owners'), key('error-reports'), key('requeued-by'), key('leases')],
            argv: [entry, error.to_s, config.redis_ttl, lease.to_s],
            pipeline: pipeline,
          ) == 1
        end

        def requeue(entry, offset: Redis.requeue_offset)
          reservation = CI::Queue::QueueEntry.reservation_key(entry)
          assert_reserved!(reservation)
          entry = reserved_entries.fetch(reservation, entry)
          lease = @reserved_leases.delete(reservation)
          unreserve_entry(reservation)
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
              key('requeued-by'),
              key('leases'),
            ],
            argv: [config.max_requeues, global_max_requeues, entry, offset, config.redis_ttl, lease.to_s],
          ) == 1

          unless requeued
            reserved_tests << reservation
            reserved_entries[reservation] = entry
            reserved_entry_ids[entry] = reservation
            @reserved_leases[reservation] = lease if lease
          end
          requeued
        end

        def release!
          eval_script(
            :release,
            keys: [key('running'), key('worker', worker_id, 'queue'), key('owners'), key('leases')],
            argv: [],
          )
          nil
        end

        private

        attr_reader :index

        # File-affinity: load the file once, discover its tests, and run all
        # of them under the file's reservation/lease. The file is the work
        # unit ci-queue tracks; per-test results are recorded out-of-band
        # via BuildStatusRecorder + record_test_result.lua.
        def process_file_entry(entry)
          file_path = CI::Queue::QueueEntry.file_path(entry)
          lease = lease_for(entry)
          reservation = Reservation.new(type: :file, entry: entry, lease: lease)
          deadline = file_affinity_deadline
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          examples = file_entry_discovery.enumerator([file_path]).to_a
          record_file_affinity_discovery(examples.size)

          examples.each do |example|
            yield_reservation(example, reservation) { |*args| yield(*args) }
            warn_file_over_soft_cap(file_path, deadline) if deadline && over_soft_cap?(deadline)
          end

          record_file_affinity_completion(file_path, started_at)
          acknowledge(entry)
        rescue ReservationError
          # The file is no longer reserved by us (already acked, or lease
          # was reassigned via reserve_lost). Nothing more to do.
        rescue *CONNECTION_ERRORS
          raise
        rescue => e
          build.report_worker_error(e)
          # Leave the file unacked: reserve_lost.lua will reclaim it for
          # another worker.
          raise
        end

        # Yield the example with optional reservation context for callers
        # that opt in to a 2-arg block. Sets `current_reservation` for the
        # duration of the yield so heartbeat/requeue paths can read it.
        def yield_reservation(example, reservation)
          previous = @current_reservation
          @current_reservation = reservation
          if block_given?
            yield example, reservation
          end
        ensure
          @current_reservation = previous
        end

        # Lazily construct a LazyTestDiscovery on first file entry. Defer
        # the require so non-file-affinity workers don't pay for loading
        # discovery infrastructure.
        def file_entry_discovery
          @file_entry_discovery ||= begin
            require 'minitest/queue/lazy_test_discovery'
            Minitest::Queue::LazyTestDiscovery.new(
              loader: file_loader,
              resolver: CI::Queue::ClassResolver,
            )
          end
        end

        def file_affinity_deadline
          cap = config.file_affinity_max_file_seconds
          return nil unless cap && cap > 0
          Process.clock_gettime(Process::CLOCK_MONOTONIC) + cap
        end

        def over_soft_cap?(deadline)
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        end

        # Idempotent: only emit one warning per file even if many tests
        # cross the cap inside the same file.
        def warn_file_over_soft_cap(file_path, deadline)
          @file_affinity_warned_for ||= {}
          return if @file_affinity_warned_for[file_path]
          @file_affinity_warned_for[file_path] = true
          build.record_warning(
            Warnings::FILE_AFFINITY_FILE_OVER_CAP,
            file_path: file_path,
            cap_seconds: config.file_affinity_max_file_seconds,
          )
        end

        # Increment a Redis counter of total examples discovered across all
        # workers. Feeds (1) the global requeue-tolerance denominator (so
        # `--requeue-tolerance` is closer to the per-test denominator we'd
        # have under eager mode) and (2) the worker profile `tests_discovered`
        # field.
        def record_file_affinity_discovery(count)
          return if count.to_i <= 0
          redis.pipelined do |pipeline|
            pipeline.incrby(key('file-affinity-discovered-tests'), count)
            pipeline.expire(key('file-affinity-discovered-tests'), config.redis_ttl)
          end
        rescue *CONNECTION_ERRORS
          # Counter is best-effort; failure here just means the global
          # denominator stays at the file count for a bit longer.
        end

        def file_affinity_discovered_tests
          redis.get(key('file-affinity-discovered-tests')).to_i
        rescue *CONNECTION_ERRORS
          0
        end

        # Per-file completion bookkeeping for the worker profile.
        SLOW_FILE_TRACK_LIMIT = 100
        private_constant :SLOW_FILE_TRACK_LIMIT

        def record_file_affinity_completion(file_path, started_at)
          duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
          @file_affinity_files_run = file_affinity_files_run + 1
          file_affinity_per_file_timings << duration

          slow_list = (@file_affinity_slow_files ||= [])
          slow_list << [file_path, duration]
          # Keep only the top SLOW_FILE_TRACK_LIMIT slowest entries to bound memory.
          if slow_list.size > SLOW_FILE_TRACK_LIMIT
            slow_list.sort_by! { |_, d| -d }
            slow_list.slice!(SLOW_FILE_TRACK_LIMIT..-1)
          else
            slow_list.sort_by! { |_, d| -d }
          end
        end

        def reserved_tests
          @reserved_tests ||= Concurrent::Set.new
        end

        def reserved_entries
          @reserved_entries ||= Concurrent::Map.new
        end

        def reserved_entry_ids
          @reserved_entry_ids ||= Concurrent::Map.new
        end

        def worker_id
          config.worker_id
        end

        def assert_reserved!(reservation)
          unless reserved_tests.include?(reservation)
            raise ReservationError, "Acknowledged #{reservation.inspect} but only #{reserved_tests.map(&:inspect).join(", ")} reserved"
          end
        end

        def reserve_entry(entry, lease = nil)
          reservation = CI::Queue::QueueEntry.reservation_key(entry)
          reserved_tests << reservation
          reserved_entries[reservation] = entry
          reserved_entry_ids[entry] = reservation
          @reserved_leases[reservation] = lease if lease
        end

        def unreserve_entry(reservation)
          entry = reserved_entries.delete(reservation)
          reserved_tests.delete(reservation)
          reserved_entry_ids.delete(entry) if entry
        end

        def queue_entry_for(test)
          return test.queue_entry if test.respond_to?(:queue_entry)
          return test.id if test.respond_to?(:id)

          test
        end

        def resolve_entry(entry)
          # Index lookups are keyed by test_id (from populate). Reservation
          # keys may include a `file:<path>` prefix for file entries, so we
          # only honour `reserved_entry_ids` when it stores a test-id-shaped
          # value. For test entries this preserves today's behaviour;
          # for file entries (handled by process_file_entry, not this path)
          # we fall through to entry_resolver / UnresolvedEntry.
          test_id = CI::Queue::QueueEntry.test_id(entry)
          reserved_key = reserved_entry_ids[entry]
          test_id ||= reserved_key if reserved_key && !reserved_key.start_with?('file:')

          if populated? && test_id
            return index[test_id] if index.key?(test_id)
          end

          return entry_resolver.call(entry) if entry_resolver

          UnresolvedEntry.new(test_id, entry)
        end

        def still_streaming?
          master_status == 'streaming'
        end

        def streaming_stale?
          timeout = config.lazy_load_streaming_timeout.to_i
          updated_at = redis.get(key('streaming-updated-at'))
          return true unless updated_at

          (CI::Queue.time_now.to_f - updated_at.to_f) > timeout
        rescue *CONNECTION_ERRORS
          false
        end

        def start_streaming!
          timeout = config.lazy_load_streaming_timeout.to_i
          with_redis_timeout(5) do
            redis.multi do |transaction|
              transaction.set(key('total'), 0)
              transaction.set(key('master-status'), 'streaming')
              transaction.set(key('streaming-updated-at'), CI::Queue.time_now.to_f)
              transaction.expire(key('streaming-updated-at'), timeout)
              transaction.expire(key('queue'), config.redis_ttl)
              transaction.expire(key('total'), config.redis_ttl)
              transaction.expire(key('master-status'), config.redis_ttl)
            end
          end
        end

        def push_batch(tests, random)
          # Use plain shuffle instead of Queue.shuffle — the custom shuffler expects
          # test objects with .id, but streaming entries are pre-formatted strings.
          entries = tests.shuffle(random: random).map { |test| queue_entry_for(test) }
          return if entries.empty?

          @total += entries.size
          timeout = config.lazy_load_streaming_timeout.to_i
          redis.multi do |transaction|
            transaction.lpush(key('queue'), entries)
            transaction.incrby(key('total'), entries.size)
            transaction.set(key('master-status'), 'streaming')
            transaction.set(key('streaming-updated-at'), CI::Queue.time_now.to_f)
            transaction.expire(key('streaming-updated-at'), timeout)
            transaction.expire(key('queue'), config.redis_ttl)
            transaction.expire(key('total'), config.redis_ttl)
            transaction.expire(key('master-status'), config.redis_ttl)
          end
        end

        def finalize_streaming
          redis.multi do |transaction|
            transaction.set(key('master-status'), 'ready')
            transaction.expire(key('master-status'), config.redis_ttl)
            transaction.del(key('streaming-updated-at'))
          end
        end

        def reserve
          entry, lease = try_to_reserve_lost_test || try_to_reserve_test || [nil, nil]
          if entry
            @first_reserve_at ||= Process.clock_gettime(Process::CLOCK_MONOTONIC)
            reserve_entry(entry, lease)
          end
          entry
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
              key('requeued-by'),
              key('workers'),
              key('leases'),
              key('lease-counter'),
            ],
            argv: [CI::Queue.time_now.to_f, Redis.requeue_offset],
          )
        end

        def try_to_reserve_lost_test
          timeout = config.max_missed_heartbeat_seconds ? config.max_missed_heartbeat_seconds : config.timeout

          result = eval_script(
            :reserve_lost,
            keys: [
              key('running'),
              key('processed'),
              key('worker', worker_id, 'queue'),
              key('owners'),
              key('leases'),
              key('lease-counter'),
            ],
            argv: [CI::Queue.time_now.to_f, timeout],
          )

          if result
            entry = result.is_a?(Array) ? result[0] : result
            build.record_warning(Warnings::RESERVED_LOST_TEST, test: CI::Queue::QueueEntry.test_id(entry), timeout: config.timeout)
            if CI::Queue.debug?
              $stderr.puts "[ci-queue][reserve_lost] worker=#{worker_id} test_id=#{CI::Queue::QueueEntry.test_id(entry)}"
            end
          end

          result
        end

        def push(entries)
          @total = entries.size

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
                    transaction.lpush(key('queue'), entries) unless entries.empty?
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
