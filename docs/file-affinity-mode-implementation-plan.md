# ci-queue file-affinity mode — final implementation plan

> Status: ready for implementation. Synthesises the original draft and a competing
> refinement, anchored to ci-queue 0.91 source. Everything below is implementable
> without further design decisions except the two items in §15.

---

## 1. Goals, non-goals, incompatibilities

### Goals
- New ci-queue mode where the queue unit is a **test file**, not a test method.
- Workers load each file at most once.
- First pass distributes file entries; per-test results are still reported as today.
- Failed tests are requeued **individually** on retry, not as whole files.
- Opt-in per namespace, so integration suites can stay on the existing path.

### Non-goals (v1)
- Splitting very large files into multiple chunks (`file_affinity_max_file_seconds`
  is **warn-only** in v1; see §7.4).
- Dynamic balancing based on historical test duration.
- Changing eager / lazy / preresolved behaviour.

### Explicit incompatibilities (rejected at CLI parse time)
- `--preresolved-tests`
- bisect (`--failing-test`)
- grind (`--grind-list` / `--grind-count`)
- non-Redis (Static / file://) queues
- non-`run` subcommands

`--file-affinity` may be combined with `--lazy-load` (it is a stricter form of lazy).

---

## 2. Mental model

The most important insight from the audit:

**`BuildStatusRecorder` (a Minitest reporter) is the place that drives ack and accounting today — not `Minitest::Queue.handle_test_result`.**
See `ruby/lib/minitest/queue/build_status_recorder.rb:42-65`:

```ruby
acknowledged = if (test.failure || test.error?) && !test.skipped?
  build.record_error(entry, dump(test), stat_delta: delta)
elsif test.requeued?
  build.record_requeue(entry)
else
  build.record_success(entry, skip_flaky_record: test.skipped?)
end
```

Both `BuildRecord#record_error` and `#record_success` call `@queue.acknowledge(entry)`,
which `assert_reserved!`s and `SADD`s `processed`. `handle_test_result` only does
requeue and circuit-breaker bookkeeping; it does **not** ack.

So in file-affinity mode we want:

1. **Per-test stats and error-reports** to keep working in the reporter exactly as
   today — except `acknowledge` is **skipped** on test entries that came from a
   file reservation.
2. **Inline (not buffered) per-test requeue** at the point of failure. The new
   test entry is in `queue` *before* the file is acked, so `running` ≥ 1 the
   whole time and there is no exhaustion race.
3. **The file entry itself is acked once** at the file boundary, via the existing
   `acknowledge.lua` (the file is a real reservation).
4. **Per-test idempotency on mid-file reclaim** is provided by a small additional
   set, `build:<id>:processed-tests`, dedup'd via `SADD`.

Everything else in this plan is a consequence of (1)–(4).

---

## 3. Final semantics

### 3.1 Initial run
- Leader streams **file entries** to Redis (`stream_populate`).
- Each worker reserves one file at a time via the existing `reserve.lua`.
- The reserving worker loads that file once through `LazyTestDiscovery` and runs
  all discovered, tag-filtered tests sequentially.
- Reporters receive normal Minitest results per test.
- The file entry is acknowledged only after the worker finishes the file.

### 3.2 Failed tests
- If `CI::Queue.requeueable?(result)` and the requeue caps allow it, the worker
  enqueues a normal test entry **immediately** via `requeue_test_only.lua`.
- The result is marked `requeued`, like today.
- Any worker may pick the retry up via the same poll loop.
- A retry test entry is handled as a normal test reservation, even when
  `file_affinity` is globally enabled — **dispatch is per-entry, not per-process.**

So: the first pass is file-granular; retries are test-granular.

### 3.3 Retry (Buildkite rerun) behaviour
- `error-reports` already contains test entries — unchanged.
- `Retry#stream_populate` ignores population and keeps existing failed entries.
- `LazyEntryResolver` resolves retry test entries by loading their file on demand.
- `reservation.type == :test` → `queue_acknowledge = true` → standard ack path.

### 3.4 Compatibility
Existing test entries remain **byte-identical** to today:
```json
{ "test_id": "Class#method", "file_path": "/abs/path.rb" }
```
Do **not** add `"type": "test"` to test entries in v1. Changing the JSON changes
Redis hash keys (`requeues-count`, `error-reports`, `processed`, `requeued-by`)
and would break rolling deploys and mixed-version builds.

New file entries:
```json
{ "type": "file", "file_path": "/abs/path.rb" }
```

Any entry without `type` is treated as a test entry.

---

## 4. Data model

### 4.1 `QueueEntry` API additions
`ruby/lib/ci/queue/queue_entry.rb`:

```ruby
def self.format_file(file_path)
  raise ArgumentError if file_path.nil? || file_path.empty?
  JSON.dump({ type: 'file', file_path: ::File.expand_path(file_path) })
end

# Hot-path fast check — avoids JSON parse on every reserve.
def self.file_entry?(entry)
  entry.start_with?('{"type":"file"')
end

def self.entry_type(entry)
  file_entry?(entry) ? :file : :test
end

def self.test_entry?(entry)
  entry_type(entry) == :test
end

def self.file_path(entry)
  parse(entry)[:file_path]
end

# Canonical reservation key used in worker bookkeeping (§4.2).
def self.reservation_key(entry)
  return "file:#{parse(entry)[:file_path]}" if file_entry?(entry)
  test_id(entry) || entry
rescue JSON::ParserError
  entry
end
```

### 4.2 Reservation-keying refactor in `redis/worker.rb`

Today the worker's `reserved_tests`, `reserved_entries`, `reserved_entry_ids`,
and `@reserved_leases` are all keyed by `test_id`. For file entries `test_id` is
`nil`, so multiple files would collide on `nil`.

Replace every reservation-bookkeeping call site with `reservation_key(entry)`:

| location | method |
|---|---|
| `redis/worker.rb:191` | `lease_for` |
| `redis/worker.rb:201` | `acknowledge` |
| `redis/worker.rb:215` | `requeue` |
| `redis/worker.rb:276` | `assert_reserved!` |
| `redis/worker.rb:303` | `resolve_entry` (only where used as a key) |
| `redis/worker.rb` private | `reserve_entry` / `unreserve_entry` |

`test_id(entry)` is **kept** for places that want the test name string
(warning messages, debug logs, reporter labels).

This refactor lands in **its own PR with no behaviour change** (PR 2), so it is
reviewable on its own.

---

## 5. Configuration and CLI

### 5.1 `Configuration` (`ruby/lib/ci/queue/configuration.rb`)

```ruby
attr_accessor :file_affinity
attr_accessor :file_affinity_max_file_seconds
```

Env wiring:
- `CI_QUEUE_FILE_AFFINITY=1` enables (truthy parse mirroring `CI_QUEUE_LAZY_LOAD`).
- `CI_QUEUE_FILE_AFFINITY_MAX_FILE_SECONDS=600` → soft cap (default unset).

Behaviour: when `file_affinity` is truthy, `lazy_load` is forced to `true`. The
runner already has the lazy execution branch we need (`Minitest.run []` instead
of `at_exit`).

### 5.2 CLI (`ruby/lib/minitest/queue/runner.rb`)

```
--file-affinity
--file-affinity-max-file-seconds SECONDS
```

Add `validate_file_affinity!` after queue creation, called before command
dispatch:

```ruby
def validate_file_affinity!
  return unless queue_config.file_affinity
  invalid_usage!("--file-affinity requires a Redis queue") unless queue.distributed?
  invalid_usage!("--file-affinity is incompatible with --preresolved-tests") if preresolved_test_list
  invalid_usage!("--file-affinity is incompatible with bisect") if queue_config.failing_test
  invalid_usage!("--file-affinity is incompatible with grind") if queue_config.grind_count
  invalid_usage!("--file-affinity is only supported for `run`") unless command == "run"
end
```

### 5.3 Heartbeat caps (clarification, not a code change)

- Per-test cap (`heartbeat_max_test_duration`) is **unchanged** — applies per
  `with_heartbeat` invocation, which in file mode is still per test.
- File-level cap (`file_affinity_max_file_seconds`) is a **separate timer**
  kept by `process_file_entry`, checked between tests. Do not reuse the
  per-test cap for this.

---

## 6. Population: leader streams file entries

### 6.1 Strategy branch (`queue_population_strategy.rb:30`)

```ruby
def populate_queue
  if queue_config.file_affinity && queue.respond_to?(:stream_populate)
    configure_lazy_queue
    queue.stream_populate(file_entry_enumerator,
                          random: ordering_seed,
                          batch_size: queue_config.lazy_load_stream_batch_size)
  elsif preresolved_test_list && queue.respond_to?(:stream_populate)
    # ... existing ...
  elsif queue_config.lazy_load && queue.respond_to?(:stream_populate)
    # ... existing ...
  else
    configure_lazy_queue
    queue.populate(Minitest.loaded_tests, random: ordering_seed)
  end
end
```

### 6.2 Leader does not require test files

In `load_tests`, when `queue_config.file_affinity` is true, behave like the
lazy-load branch: load only `lazy_load_test_helper_paths`. Set
`@total_files = test_file_list.size`.

### 6.3 `file_entry_enumerator`

```ruby
def file_entry_enumerator
  files = test_file_list.sort   # stable assignment
  Enumerator.new do |y|
    files.each { |path| y << CI::Queue::QueueEntry.format_file(path) }
  end
end
```

### 6.4 Worker-side discovery

Reuse `LazyTestDiscovery#each_test([file])` unchanged. Tag filter is applied
inside discovery (see §11).

---

## 7. Worker: file reservation and the per-test loop

### 7.1 `Reservation` struct (passed into the poll block)

```ruby
Reservation = Struct.new(:type, :entry, :lease, keyword_init: true) do
  def file?; type == :file; end
  def test?; type == :test; end
end
```

This is cleaner than mutable `current_reservation_*` state on the queue object:
the poll block receives the reservation as a second argument.

### 7.2 `poll` dispatch (`redis/worker.rb:108`)

```ruby
def poll
  wait_for_master(timeout: config.queue_init_timeout, allow_streaming: true)
  attempt = 0
  until shutdown_required? || config.circuit_breakers.any?(&:open?) || exhausted? || max_test_failed?
    if entry = reserve
      attempt = 0
      lease = lease_for(entry)
      if CI::Queue::QueueEntry.file_entry?(entry)
        process_file_entry(entry, lease) do |example|
          yield example, Reservation.new(type: :file, entry: entry, lease: lease)
        end
      else
        yield resolve_entry(entry), Reservation.new(type: :test, entry: entry, lease: lease)
      end
    else
      # ... existing sleep/backoff ...
    end
  end
  # ... existing TTL refresh ...
end
```

A file is reserved through the **same** `reserve.lua` used today. It enters
`running` / `owners` / `leases` exactly like a test entry, so `reserve_lost.lua`
reclaim and the heartbeat process all "just work" for files. **No reserve Lua
changes.**

`Static` and other queues that yield one block argument continue to work — Ruby
passes `nil` for the second parameter when they don't supply it.

### 7.3 `process_file_entry`

```ruby
def process_file_entry(entry, lease)
  file_path = CI::Queue::QueueEntry.file_path(entry)
  started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  examples = lazy_test_discovery.enumerator([file_path]).to_a
  record_file_discovery(file_path, examples.size)

  examples.each do |example|
    yield example
    if file_affinity_over_soft_cap?(started_at)
      record_file_affinity_warning(file_path, started_at, examples.size)
      # v1: warn only — no auto-split.
    end
  end

  acknowledge(entry)              # file ack via existing acknowledge.lua
rescue => e
  build.report_worker_error(e)
  raise                           # leave file unacked → reserve_lost reclaims
end
```

### 7.4 Why `file_affinity_max_file_seconds` is warn-only in v1

Hard-capping a file mid-run requires pushing remaining tests as test entries.
That introduces a third semantic class — *continuation* test entries that should
not count against `requeues-count` — which is effectively file chunking and was
listed as a non-goal. v1 records a warning in the worker profile and lets the
file finish; v1.1/v2 can add explicit chunking with continuation semantics if
single-file stragglers prove to be a real problem.

### 7.5 Mid-file lease loss (known limitation)

If worker A's heartbeat fails to renew the file lease, `reserve_lost.lua` may
reassign the file to worker B. Both will run the file. Mitigations:
- The new `processed-tests` set (§8.1) makes per-test recording idempotent — A
  and B can both write without double-counting.
- A's eventual `acknowledge(file_entry)` is rejected by the lease check in
  `acknowledge.lua` — B's ack is authoritative.
- v1.1: heartbeat thread sets a `lease_lost` flag the foreground checks between
  tests, so worker A bails out cleanly. Out of scope for v1.

### 7.6 Heartbeat in `Minitest::Queue.run`

```ruby
queue.poll do |example, reservation|
  heartbeat_entry = reservation&.entry || example.queue_entry
  heartbeat_lease = reservation&.lease || queue.lease_for(example.queue_entry)
  result = queue.with_heartbeat(heartbeat_entry, lease: heartbeat_lease) do
    example.run
  end
  handle_test_result(reporter, example, result, reservation)
end
```

For non-file-affinity callers (or queues that yield 1 arg), `reservation` is
`nil` and the existing per-test heartbeat is preserved.

`heartbeat_max_test_duration` remains per-`with_heartbeat`, i.e. per individual
test, even in file mode. That is what we want.

---

## 8. Per-test recording and idempotency

### 8.1 New Redis set: `build:<id>:processed-tests`

Used **only** for file-affinity per-test result recording. Purposes:
- Prevent duplicate success/failure stats if a file is reclaimed and rerun.
- Allow success-after-failure to clear the error report and apply the stat
  correction.
- Feed an explicit `tests` counter so the aggregate "Ran N tests" line stays
  test-shaped while `processed` goes file-shaped.

### 8.2 New Lua: `redis/record_test_result.lua`

```lua
local processed_tests_key  = KEYS[1]
local error_reports_key    = KEYS[2]
local requeues_count_key   = KEYS[3]
local error_report_deltas_key = KEYS[4]

local status   = ARGV[1]      -- "success" | "failure"
local entry    = ARGV[2]
local payload  = ARGV[3]      -- error payload (failure only, "" otherwise)
local ttl      = tonumber(ARGV[4])

if status == "failure" then
  local first = redis.call('sadd', processed_tests_key, entry) == 1
  if first then
    redis.call('hset', error_reports_key, entry, payload)
    if ttl and ttl > 0 then
      redis.call('expire', processed_tests_key, ttl)
      redis.call('expire', error_reports_key, ttl)
    end
    return {1, 0, false, false}
  end
  return {0, 0, false, false}
else
  local added    = redis.call('sadd', processed_tests_key, entry)
  local deleted  = redis.call('hdel', error_reports_key, entry)
  local requeues = redis.call('hget', requeues_count_key, entry)
  local delta    = redis.call('hget', error_report_deltas_key, entry)
  if ttl and ttl > 0 then
    redis.call('expire', processed_tests_key, ttl)
  end
  return {added, deleted, requeues or false, delta or false}
end
```

### 8.3 `BuildRecord` changes

Extend `Redis::BuildRecord`:
```ruby
def record_error(entry, payload, stat_delta: nil, acknowledge: true)
def record_success(entry, skip_flaky_record: false, acknowledge: true)
```

- `acknowledge: true` → existing path (ack via `acknowledge.lua`).
- `acknowledge: false` → use `record_test_result.lua`.

The success path applies the existing `apply_error_report_delta_correction` to
the delta returned by the script.

`record_error(acknowledge: false)` increments `test_failed_count` and stores the
stat delta only when `processed-tests` saw the entry for the first time
(`added == 1`).

### 8.4 Result metadata: `queue_acknowledge`

Extend `Minitest::ResultMetadata`:
```ruby
attr_accessor :queue_id
attr_accessor :queue_entry
attr_accessor :queue_acknowledge
```

In `handle_test_result`:
```ruby
result.queue_acknowledge = !reservation&.file? if result.respond_to?(:queue_acknowledge=)
```

This avoids `BuildStatusRecorder` having to introspect queue state — the
recorder reads the per-result flag.

### 8.5 `BuildStatusRecorder.record(test)` becomes file-aware

```ruby
acknowledge_kw = test.respond_to?(:queue_acknowledge) ? { acknowledge: test.queue_acknowledge != false } : {}
acknowledged = if (test.failure || test.error?) && !test.skipped?
  build.record_error(entry, dump(test), stat_delta: delta, **acknowledge_kw)
elsif test.requeued?
  build.record_requeue(entry)
else
  build.record_success(entry, skip_flaky_record: test.skipped?, **acknowledge_kw)
end
```

Dispatch is **per-entry**: a test entry retried standalone (even with global
file-affinity on) goes through the regular ack path because `reservation.test?`
is true.

---

## 9. Inline test-only requeue

### 9.1 New Lua: `redis/requeue_test_only.lua`

```lua
local processed_tests_key   = KEYS[1]
local requeues_count_key    = KEYS[2]
local queue_key             = KEYS[3]
local worker_queue_key      = KEYS[4]
local error_reports_key     = KEYS[5]
local requeued_by_key       = KEYS[6]

local max_requeues          = tonumber(ARGV[1])
local global_max_requeues   = tonumber(ARGV[2])
local entry                 = ARGV[3]
local offset                = ARGV[4]
local ttl                   = tonumber(ARGV[5])

-- already terminally recorded?
if redis.call('sismember', processed_tests_key, entry) == 1 then
  return false
end

local global_requeues = tonumber(redis.call('hget', requeues_count_key, '___total___'))
if global_requeues and global_requeues >= global_max_requeues then return false end

local requeues = tonumber(redis.call('hget', requeues_count_key, entry))
if requeues and requeues >= max_requeues then return false end

redis.call('hincrby', requeues_count_key, '___total___', 1)
redis.call('hincrby', requeues_count_key, entry, 1)

redis.call('hdel', error_reports_key, entry)

local pivot = redis.call('lrange', queue_key, -1 - offset, 0 - offset)[1]
if pivot then
  redis.call('linsert', queue_key, 'BEFORE', pivot, entry)
else
  redis.call('lpush', queue_key, entry)
end

redis.call('hset', requeued_by_key, entry, worker_queue_key)
if ttl and ttl > 0 then redis.call('expire', requeued_by_key, ttl) end

return true
```

The script does **not** touch `running`, `owners`, or `leases` — the test
entry was never individually reserved. It does **not** require a `lease_id`
match — the lease guarding the work is the file's, which stays valid.

### 9.2 Worker method

```ruby
def requeue_test_entry(entry, offset: Redis.requeue_offset)
  global_max_requeues = file_affinity_global_max_requeues
  config.max_requeues > 0 && global_max_requeues > 0 && eval_script(
    :requeue_test_only,
    keys: [
      key('processed-tests'),
      key('requeues-count'),
      key('queue'),
      key('worker', worker_id, 'queue'),
      key('error-reports'),
      key('requeued-by'),
    ],
    argv: [config.max_requeues, global_max_requeues, entry, offset, config.redis_ttl],
  ) == 1
end
```

### 9.3 Runner dispatch (`Minitest::Queue.handle_test_result`)

```ruby
if failed && CI::Queue.requeueable?(result)
  requeued = if reservation&.file?
    queue.requeue_test_entry(example.queue_entry)
  else
    queue.requeue(example.queue_entry)
  end
  result.requeue! if requeued
end
```

The new test entry is in `queue` *before* the file is acked → `running` ≥ 1
the whole time → no exhaustion race. No buffered flush is needed.

### 9.4 Global requeue tolerance denominator

`config.global_max_requeues(total)` uses `total`, which in file-affinity is the
file count — strictly stricter than today's per-test denominator. Resolution:

- Workers increment a Redis counter `build:<id>:file-affinity-discovered-tests`
  by `examples.size` immediately after discovering a file (in `process_file_entry`,
  before yielding any example).
- `requeue_test_entry` computes:
  ```ruby
  base = [total, redis.get(key('file-affinity-discovered-tests')).to_i].max
  global_max_requeues = config.global_max_requeues(base)
  ```
- This is approximate early in the run (the first few requeues may see
  `total = file_count` as the floor) but converges to the real test count as
  workers reserve files. Convergence is fast because every worker contributes.
- Future exact parity: optional `--expected-test-count` /
  `CI_QUEUE_EXPECTED_TEST_COUNT`, set from a cached test-count file on `main`.
  Out of scope for v1; the floor-and-converge default is the v1 contract.

The counter is also surfaced in worker profile output (§10.3.2) as
`tests_discovered`.

---

## 10. Counting, exhaustion, and reporting

### 10.1 Existing accounting (unchanged)

| concept | source | behaviour in file-affinity |
|---|---|---|
| `processed` (`SADD`) | `acknowledge.lua` | contains **file entries** only |
| `total` | leader sets to streamed count | = number of files |
| `exhausted?` | `size == llen(queue) + zcard(running) == 0` | works correctly |
| `failed_tests` | `hkeys(error-reports)` | still test entries |
| `test_failed_count` | INCR per failure in `record_error` | still per test |
| `requeues-count[entry]` | HINCRBY in requeue Lua | still per test entry |

### 10.2 New accounting

| concept | source | purpose |
|---|---|---|
| `processed-tests` (`SADD`) | `record_test_result.lua` | per-test idempotency for mid-file reclaim |
| `file-affinity-discovered-tests` (`INCRBY`) | worker `process_file_entry` | denominator for `--requeue-tolerance` (§9.4) |
| `tests` counter (per-worker stats hash) | `BuildStatusRecorder` delta | feeds aggregate "Ran N tests" line |

### 10.3 Reporter and profile changes

#### 10.3.1 Build status aggregate (`build_status_reporter.rb` / `build_status_recorder.rb`)

Add `tests` to `COUNTERS`:
```ruby
COUNTERS = %w(tests assertions errors failures skips requeues total_time).freeze
```

In `delta_for(test)`:
- terminal success / failure / skip → `tests = 1`
- requeued attempt → `tests = 0`

Aggregate display falls back gracefully:
```ruby
tests_run = fetch_summary['tests'].to_i
tests_run = progress if tests_run.zero? && progress.nonzero?
```

In file-affinity mode, label work-unit progress as files (or work units) when
shown — `progress` becomes file-shaped. Failure summaries stay test-based via
`error-reports`.

#### 10.3.2 Worker profile (`minitest/queue.rb` `store_worker_profile` + `worker_profile_reporter.rb`)

Mode label:
```ruby
mode = if config.file_affinity then 'file_affinity'
       elsif config.lazy_load   then 'lazy'
       else                          'eager'
       end
```

File-affinity-specific fields, populated by the worker during
`process_file_entry`:

| field | meaning |
|---|---|
| `files_run` | count of file entries fully processed by this worker |
| `tests_run` | count of per-test results emitted (not work-units) |
| `tests_discovered` | total examples yielded by `LazyTestDiscovery` for this worker (matches `file-affinity-discovered-tests` contribution) |
| `entries_reserved` | reserved work units, including retries (replaces `worker_queue_length` as the test-count proxy) |
| `slow_files` | up to N (e.g. 10) `[file_path, duration]` tuples with the longest single-file wall-clocks |
| per-file timings | enough raw data to print P50 / P95 / P99 across the supervisor aggregation |
| `worker_rss_kb` | already collected; keep |
| `time_to_first_test` | already collected via `first_reserve_at`; keep |

Explicitly **do not** treat `worker_queue_length` as `tests_run` in file-affinity
mode — it now counts reserved work units (mostly files plus retried test entries).

The supervisor aggregates per-file timings across all workers and prints per-file
**P50/P95/P99 wall-clock** as the headline file-affinity metric — this is what
justifies file-affinity vs plain lazy mode and drives the cutover decision.

#### 10.3.3 Other reporters

No expected v1 code changes:

- `JUnitReporter` — per-test, unchanged.
- `TestDataReporter` — per-test, unchanged.
- `OrderReporter` — per-test, unchanged.
- `TestTimeReporter` — per-test, unchanged.

Known caveat: on mid-file reclaim, the same `test_id` may appear twice in
local per-worker output / JUnit artifacts (one entry per worker that ran it).
Accept for v1; monitor downstream consumers.

---

## 11. Tag filter: `CI::Queue.test_inclusion_filter`

Global extension point:
```ruby
module CI
  module Queue
    class << self
      attr_accessor :test_inclusion_filter
    end

    def self.include_test?(runnable, method_name)
      filter = @test_inclusion_filter
      return true unless filter
      filter.call(runnable, method_name)
    end
  end
end
```

Default: `nil` (keep all tests). Apply inside
`LazyTestDiscovery#enqueue_discovered_tests` **before** yielding a
`LazySingleExample`:

```ruby
runnable.runnable_methods.each do |method_name|
  test_id = "#{runnable.name}##{method_name}"
  next if seen.include?(test_id)
  next unless CI::Queue.include_test?(runnable, method_name)
  seen.add(test_id)
  yield Minitest::Queue::LazySingleExample.new(...)
rescue NameError, NoMethodError
  next
end
```

Also apply in `Minitest::Queue.loaded_tests` (eager path) for symmetry. Load-error
synthetic examples bypass the filter.

This fixes tag-filter coverage in lazy mode, file-affinity mode, and the
preresolved reconcile-discovery path simultaneously.

**Ship as PR 1, on its own** — independent value, removes a confounder.

---

## 12. Lua scripts touched

| script | change |
|---|---|
| `redis/reserve.lua` | none |
| `redis/reserve_lost.lua` | none |
| `redis/heartbeat.lua` | none |
| `redis/release.lua` | none |
| `redis/acknowledge.lua` | none (used as-is for file ack) |
| `redis/requeue.lua` | none |
| **`redis/record_test_result.lua`** | new (§8.2) |
| **`redis/requeue_test_only.lua`** | new (§9.1) |

Two new scripts, no edits to existing ones.

---

## 13. Tests

### 13.1 ci-queue gem

- `ruby/test/ci/queue/queue_entry_test.rb`
  - file entry roundtrip (`format_file` / `file_entry?` / `file_path`)
  - test entry remains byte-stable (no `type` field)
  - `entry_type` defaults to `:test` for legacy entries
  - `reservation_key` for file entries is non-nil and unique
  - `reservation_key` for test entries equals `test_id`

- `ruby/test/ci/queue/redis/worker_reservation_test.rb`
  - multiple file entries reserved without nil-key collisions
  - `lease_for(file_entry)` returns the correct lease
  - `acknowledge(file_entry)` works through existing `acknowledge.lua`

- `ruby/test/ci/queue/redis/lua_test.rb` extensions
  - `record_test_result.lua`: success records once; duplicate success is
    idempotent; failure records once; failure→success clears error and
    returns the correction delta
  - `requeue_test_only.lua`: per-test cap, global cap, offset insert,
    `requeued-by` set, no `running`/`owners`/`leases` mutation, refuses
    re-requeue once `processed-tests` contains the entry

- `ruby/test/integration/file_affinity_test.rb` (with embedded redis-server)
  - 2 files / 2 workers: each file reserved once, tests reported individually,
    aggregate count is test count
  - failed test in file: marked requeued locally, pushed as test entry,
    retried by another worker, success clears error report
  - requeue cap denied: failure recorded in error-reports, file still acked
  - load-error file: synthetic load-error example reported, file acked
  - reclaimed file: per-test stats are idempotent via `processed-tests`

- `ruby/test/minitest/queue/queue_population_strategy_file_affinity_test.rb`
  - leader streams file entries
  - leader does not require test files
  - `--test-files` input works
  - `--preresolved-tests` rejected with `--file-affinity`

- `ruby/test/minitest/queue/lazy_test_discovery_filter_test.rb`
  - filter excludes tests before yielding
  - load-error examples bypass filter
  - default filter keeps all tests

- Runner validation
  - `--file-affinity` rejects bisect, grind, preresolved, non-Redis queue
  - `--file-affinity` forces lazy execution path

### 13.2 shop-server

Smoke tests for known-flaky-ish areas (e.g. `SplitDeliveryMethodsIntegrationTest`,
`ShopEligibilitySignalTest`) under file-affinity, plus the standard CI run.

---

## 14. shop-server changes

### 14.1 Bump ci-queue
After the ci-queue release, bump `Gemfile`/`Gemfile.lock` to the new version.

### 14.2 Configure tag filter
In `lib/minitest/tagging.rb` (or equivalent test-helper init):
```ruby
require 'ci/queue'
CI::Queue.test_inclusion_filter = ->(runnable, method_name) {
  Minitest::Tagging.match?(runnable, method_name)
}
```
Guard for older ci-queue versions during rollout if needed.

### 14.3 `bin/test`
When `CI_QUEUE_FILE_AFFINITY=1`:
```ruby
cmd << "--file-affinity"
cmd << "--heartbeat" << "30"
cmd << "--heartbeat-max-test-duration" << "600"
```
Keep existing `--max-requeues 5`, `--requeue-tolerance 0.01`. Pass test files
positionally or via `--test-files`.

### 14.4 New Buildkite namespace `main-file-affinity`
`.shopify-build/shared/test_steps.yml`:
```yaml
run_ruby_tests_file_affinity: &run_ruby_tests_file_affinity
  <<: *run_ruby_tests
  label: ':ruby: Ruby Tests (file-affinity)'
  env:
    DISABLE_TOXIPROXY: "true"
    CI_QUEUE_FILE_AFFINITY: "1"
    CI_QUEUE_LAZY_LOAD_TEST_HELPERS: "test/test_helper.rb"
    CI_QUEUE_FILE_AFFINITY_MAX_FILE_SECONDS: "600"
  run:
    - cd areas/platforms/shop-server
    - bundle: { check: true }
    - bundle exec bin/ci/check-queue-exhausted "${MINITEST_QUEUE_NAMESPACE:-main-file-affinity}"; [ $? -eq 42 ] && exit 0; true
    - bin/db-started
    - SQL_MAX_EXECUTION_TIME=30000 bundle exec rake retry_ci:timed:db:create retry_ci:timed:db:schema:load retry_ci:timed:elasticsearch:create --trace
    - MINITEST_QUEUE_NAMESPACE=main-file-affinity bin/test --all-tests-in-parallel
  parallelism: 90
```
Plus a matching `Ruby Tests (file-affinity) Summary` step.

Integration namespaces (bigtable, activekafka, system, toxiproxy, non-transactional)
**stay on existing eager mode** for v1.

### 14.5 Rollout strategy

To avoid doubling spend on every PR:
1. **Day 0–3**: shadow-run on `main` post-merge only.
2. **Day 3–7**: random subset of PRs (e.g. 10%) via pipeline switch.
3. **Day 7+**: full cutover if metrics are net-positive.

Compare-and-decide metrics:
- total wall-clock per parallel slot
- per-worker time-to-first-test
- per-file P50/P95/P99 wall-clock (new — most important)
- retry rate (`requeues-count` total / total)
- mid-file reclaim count (`RESERVED_LOST_TEST` warnings on file entries)
- exit-83 / OOM rate
- worker RSS
- first-failure surfacing speed
- final failure parity vs the existing `main` namespace

Per the autoresearch lesson logged 2026-04-22: only **back-to-back A/B with
the same host load snapshot** is trustworthy for the cutover decision; 3-run
means across hours can be confounded by host-load drift.

---

## 15. Open decisions

Only one product call remains; everything else has a concrete v1 default.

1. **`file_affinity_max_file_seconds` semantics**
   - **v1 (default)**: warn-only — records a `RESERVED_LOST_TEST`-style warning,
     lets the file finish. The signal feeds the `slow_files` field of the
     worker profile.
   - Hard cap requires *continuation* test entries with separate accounting,
     which is file chunking and a non-goal. v1.1/v2 follow-up.

*Resolved* (v1 contract):

- **Global requeue tolerance**: `max(total, file-affinity-discovered-tests)` as
  the denominator (§9.4). Optional exact-parity escape via
  `CI_QUEUE_EXPECTED_TEST_COUNT` is a v1.1 addition, not v1.

---

## 16. PR slicing

| PR | Repo | Scope | Risk |
|---|---|---|---|
| **1** | ci-queue | `CI::Queue.test_inclusion_filter` extension point + applied in `LazyTestDiscovery` and `Minitest::Queue.loaded_tests`. Tests. Independently valuable; removes a confounder. | Low (no semantic change unless filter is set) |
| **2** | ci-queue | `QueueEntry` API (`format_file`, `file_entry?`, `entry_type`, `reservation_key`) + reservation-keying refactor in `worker.rb`. **No new flag, no behaviour change.** Tests for `reservation_key`. | Medium (touches every reservation map; high-risk change in isolation) |
| **3** | ci-queue | Configuration / env / CLI flags + `validate_file_affinity!` + `queue_population_strategy` branch + `file_entry_enumerator`. Flag is accepted but rejected at runtime worker dispatch with a clear message. | Low (gated) |
| **4** | ci-queue | `Worker#process_file_entry`, `poll` yields `Reservation`, runner heartbeat by reservation entry, `queue_acknowledge` result metadata, `record_test_result.lua`, `processed-tests` set, `BuildRecord#record_*(acknowledge:)`, `BuildStatusRecorder` `tests` counter, mode label. Integration tests. | Highest (the actual feature) |
| **5** | ci-queue | `requeue_test_only.lua`, `Worker#requeue_test_entry`, runner branches on reservation type, retry integration tests, soft cap warning. | Medium |
| **6** | shop-server | Bump ci-queue, set `CI::Queue.test_inclusion_filter` from `lib/minitest/tagging.rb`, `--file-affinity` plumbing in `bin/test`, new Buildkite `main-file-affinity` namespace + summary, run shadow-only on main. Debug profile enabled. | Low (additive) |
| **7** | shop-server | Cutover main namespace to file-affinity; retire shadow step. | Operational |

PR 1 ships first because it can land and bake without anyone enabling
file-affinity. PR 2 (the reservation-key refactor) is intentionally separated
from any flag work so the high-blast-radius edit is reviewable on its own.

---

## 17. Risks and tradeoffs

| # | Risk | v1 stance |
|---|---|---|
| 1 | Mid-file reclaim re-runs all tests in the file | Accept; document; cap with `MAX_FILE_SECONDS` warn; track reclaim count |
| 2 | Mid-file reclaim writes to `error-reports` from two workers | Idempotent via `processed-tests` SADD; v1.1 add lease-lost detection |
| 3 | JUnit reporter emits same test twice on reclaim | Accept; consumers tolerate |
| 4 | Single-file straggler dominates wall-clock | Soft cap warning + manual file split; v2 chunking |
| 5 | Per-worker memory grows (more requires per worker) | Monitor RSS; tune file-affinity worker count if OOMs appear |
| 6 | Tests assume file-level fixture state across reclaim | Same assumption today; document |
| 7 | Tag-filter rollout may surface previously-skipped tests | PR 1 is independent; bakes in lazy mode first |
| 8 | Bisect / grind / preresolved combos | Hard-rejected at CLI parse time |
| 9 | Local dev (`bin/test some_file.rb`) | File-affinity disabled when `CI_QUEUE_FILE_AFFINITY` unset |
| 10 | Doubling CI spend during shadow window | Shadow on main only first; gated PR rollout; bounded duration |

---

## 18. Code-touch summary

ci-queue gem files modified:
- `ruby/lib/ci/queue/queue_entry.rb`
- `ruby/lib/ci/queue/configuration.rb`
- `ruby/lib/ci/queue.rb` (test_inclusion_filter)
- `ruby/lib/ci/queue/redis/worker.rb`
- `ruby/lib/ci/queue/redis/build_record.rb`
- `ruby/lib/minitest/queue.rb`
- `ruby/lib/minitest/queue/runner.rb`
- `ruby/lib/minitest/queue/queue_population_strategy.rb`
- `ruby/lib/minitest/queue/lazy_test_discovery.rb`
- `ruby/lib/minitest/queue/build_status_recorder.rb`
- `ruby/lib/minitest/queue/build_status_reporter.rb` (aggregate label, tests counter)
- `ruby/lib/minitest/queue/worker_profile_reporter.rb`

New Lua scripts:
- `redis/record_test_result.lua`
- `redis/requeue_test_only.lua`

shop-server files modified (PR 6/7):
- `Gemfile` / `Gemfile.lock`
- `lib/minitest/tagging.rb` (set filter)
- `bin/test` (`--file-affinity` plumbing)
- `.shopify-build/shared/test_steps.yml` (new namespace + summary)

No changes to existing Lua, no changes to RSpec wiring, no changes to existing
reporters' record-keying.
