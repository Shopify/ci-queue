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

        def poll
          wait_for_master(timeout: config.queue_init_timeout, allow_streaming: true)
          attempt = 0
          until shutdown_required? || config.circuit_breakers.any?(&:open?) || exhausted? || max_test_failed?
            if entry = reserve
              attempt = 0
              yield resolve_entry(entry)
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
          test_id = CI::Queue::QueueEntry.test_id(entry)
          @reserved_leases[test_id]
        end

        def report_worker_error(error)
          build.report_worker_error(error)
        end

        def acknowledge(entry, error: nil, pipeline: redis)
          test_id = CI::Queue::QueueEntry.test_id(entry)
          assert_reserved!(test_id)
          entry = reserved_entries.fetch(test_id, entry)
          lease = @reserved_leases.delete(test_id)
          unreserve_entry(test_id)
          eval_script(
            :acknowledge,
            keys: [key('running'), key('processed'), key('owners'), key('error-reports'), key('requeued-by'), key('leases')],
            argv: [entry, error.to_s, config.redis_ttl, lease.to_s],
            pipeline: pipeline,
          ) == 1
        end

        def requeue(entry, offset: Redis.requeue_offset)
          test_id = CI::Queue::QueueEntry.test_id(entry)
          assert_reserved!(test_id)
          entry = reserved_entries.fetch(test_id, entry)
          lease = @reserved_leases.delete(test_id)
          unreserve_entry(test_id)
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
            reserved_tests << test_id
            reserved_entries[test_id] = entry
            reserved_entry_ids[entry] = test_id
            @reserved_leases[test_id] = lease if lease
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

        def assert_reserved!(test_id)
          unless reserved_tests.include?(test_id)
            raise ReservationError, "Acknowledged #{test_id.inspect} but only #{reserved_tests.map(&:inspect).join(", ")} reserved"
          end
        end

        def reserve_entry(entry, lease = nil)
          test_id = CI::Queue::QueueEntry.test_id(entry)
          reserved_tests << test_id
          reserved_entries[test_id] = entry
          reserved_entry_ids[entry] = test_id
          @reserved_leases[test_id] = lease if lease
        end

        def unreserve_entry(test_id)
          entry = reserved_entries.delete(test_id)
          reserved_tests.delete(test_id)
          reserved_entry_ids.delete(entry) if entry
        end

        def queue_entry_for(test)
          return test.queue_entry if test.respond_to?(:queue_entry)
          return test.id if test.respond_to?(:id)

          test
        end

        def resolve_entry(entry)
          test_id = reserved_entry_ids[entry] || CI::Queue::QueueEntry.test_id(entry)
          if populated?
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
