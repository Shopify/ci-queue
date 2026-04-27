## Installation

Add this line to your application's Gemfile:

```ruby
gem 'ci-queue'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install ci-queue

## Usage

### Supported CI providers

`ci-queue` automatically infers most of its configuration if ran on one of the following CI providers:

  - Buildkite
  - CircleCI
  - Travis
  - Heroku CI
  - Semaphore 2

If you are using another CI system, please refer to the command usage message.

### Minitest

Assuming you use one of the supported CI providers, the command can be as simple as:

```bash
minitest-queue --queue redis://example.com run -Itest test/**/*_test.rb
```

Additionally you can configure the requeue settings (see main README) with `--max-requeues` and `--requeue-tolerance`.

#### Lazy loading (opt-in)

By default, all test files are loaded upfront before any tests run. Lazy loading changes this
so that test files are loaded on-demand as each test is dequeued, reducing peak memory usage.
This is supported only by `minitest-queue` (not `rspec-queue`).

```bash
minitest-queue --queue redis://example.com --lazy-load run -Itest test/**/*_test.rb
```

The leader discovers tests from the provided files, streams them to Redis in batches, and
workers start running tests as soon as the first batch arrives. Each worker only loads the
test files it actually needs.

In lazy-load mode, test files are not loaded at startup. If your test suite requires a boot
file (e.g., `test/test_helper.rb` for Rails), specify it so all workers load it before
running tests.

**CLI flags:**

| Flag | Description |
|---|---|
| `--lazy-load` | Enable lazy loading mode |
| `--lazy-load-stream-batch-size SIZE` | Number of tests per batch streamed to Redis (default: 5000) |
| `--lazy-load-stream-timeout SECONDS` | Max time for the leader to finish streaming (default: 300s or `--queue-init-timeout`, whichever is larger) |
| `--test-files FILE` | Read test file paths from FILE (one per line) instead of positional args. Avoids ARG_MAX limits for large suites (36K+ files). |

**Environment variables:**

| Variable | Description |
|---|---|
| `CI_QUEUE_LAZY_LOAD=1` | Enable lazy loading (equivalent to `--lazy-load`) |
| `CI_QUEUE_LAZY_LOAD_STREAM_BATCH_SIZE=N` | Same as `--lazy-load-stream-batch-size` |
| `CI_QUEUE_LAZY_LOAD_STREAM_TIMEOUT=N` | Same as `--lazy-load-stream-timeout` |
| `CI_QUEUE_LAZY_LOAD_TEST_HELPERS=path` | Comma-separated list of helper files to load at startup on all workers (e.g., `test/test_helper.rb`). No CLI equivalent. |

Backward-compatible env var aliases: `CI_QUEUE_STREAM_BATCH_SIZE`, `CI_QUEUE_STREAM_TIMEOUT`, `CI_QUEUE_TEST_HELPERS`.

When `CI_QUEUE_DEBUG=1` is set, file loading stats are printed at the end of the run.

#### File-affinity mode (opt-in)

File-affinity mode treats each **test file** as the queue's work unit instead of each
test method. The leader streams file paths to Redis; each worker reserves one file
at a time, loads it once, runs all of its tests, and acknowledges the file. Per-test
results, error reporting, and per-test inline retries are unchanged.

This amortizes per-file fixed costs (Rails boot for a fresh worker, one-shot file
`require`, fixture file `setup_all`) across all of a file's tests instead of paying
them once per test. For Rails-heavy suites where a single worker may run many tests
from the same file, this can substantially reduce wall-clock and per-worker memory.

```bash
minitest-queue --queue redis://example.com --file-affinity \
  --heartbeat 30 --heartbeat-max-test-duration 600 \
  run -Itest test/**/*_test.rb
```

**Semantics**

- *First pass* is file-granular. Each file is reserved by exactly one worker.
- *Failed tests* are requeued individually as test entries (not the whole file)
  via a separate Lua path, so retries are picked up by any worker. Per-test
  `--max-requeues` and `--requeue-tolerance` work as today.
- *Mid-file reclaim* (worker crashes / heartbeat expires) re-runs the entire
  file on another worker. A separate `processed-tests` Redis set deduplicates
  per-test results across reclaim, so stats stay correct.
- *Soft-cap warning*: if a single file takes longer than
  `--file-affinity-max-file-seconds`, a `FILE_AFFINITY_FILE_OVER_CAP` warning
  is recorded but the file finishes (warn-only in v1).
- Implies `--lazy-load`. The leader requires only `lazy_load_test_helpers`,
  not test files.
- Incompatible with `--preresolved-tests`, bisect, and grind. Redis-only.

**CLI flags**

| Flag | Description |
|---|---|
| `--file-affinity` | Enable file-affinity mode |
| `--file-affinity-max-file-seconds SECONDS` | Soft per-file cap. Warn-only in v1; the file still finishes. |

**Environment variables**

| Variable | Description |
|---|---|
| `CI_QUEUE_FILE_AFFINITY=1` | Equivalent to `--file-affinity` |
| `CI_QUEUE_FILE_AFFINITY_MAX_FILE_SECONDS=N` | Same as `--file-affinity-max-file-seconds` |

**Worker profile**

With `CI_QUEUE_DEBUG=1`, the supervisor prints a file-affinity-specific
summary at the end of the run:

```
Worker profile summary (90 workers, mode: file_affinity):
  Worker       Role          Files    Tests       1st Test     Wall Clock     File P95     Memory
  ----------------------------------------------------------------------------------------------------
  0            leader          412      28012        0.36s        540.12s       12.04s     934 MB
  1            non-leader      407      28012        0.41s        538.55s       11.92s     921 MB
  ...

  File-affinity aggregates:
    Files run total:     36000
    Tests discovered:    28012
    Per-file wall clock: P50=0.42s  P95=12.04s  P99=24.81s  max=87.30s
    Slowest files:
       87.30s  test/integration/some_pathological_test.rb
       ...
```

The `Per-file wall clock` percentiles are the headline metric for evaluating
file-affinity wins vs lazy / eager modes.

**Tag filtering bridge**

In lazy and file-affinity modes the leader does not call `Minitest.loaded_tests`,
so a host app's tag-filtering code that hooks `loaded_tests` is bypassed. Wire
filtering through the new extension point instead:

```ruby
require 'ci/queue'

CI::Queue.test_inclusion_filter = ->(runnable, method_name) {
  MyApp::Tagging.match?(runnable, method_name)
}
```

The filter is consulted inside lazy discovery (and the eager `loaded_tests`
fallback for symmetry), so tagged-out tests never become queue entries.
Load-error synthetic examples bypass the filter so broken files still surface.

For the full design, semantics, and rollout plan, see
[`docs/file-affinity-mode-implementation-plan.md`](../docs/file-affinity-mode-implementation-plan.md).

#### Preresolved test names (opt-in)

For large test suites, you can pre-compute the full list of test names on a stable branch
(e.g., `main`) and cache it. On feature branches, ci-queue reads test names from the cache
instead of loading all test files to discover them. This eliminates the upfront discovery
cost and implies lazy-load mode for all workers.

```bash
minitest-queue --queue redis://example.com run \
  --preresolved-tests test_names.txt \
  -I. -Itest
```

The file format is one test per line: `TestClass#method_name|path/to/test_file.rb`.
The pipe-delimited file path tells ci-queue which file to load when a worker picks up that test.
The leader streams entries directly to Redis without loading any test files.

**Reconciliation**: The cached test list may become stale when test files change between
the cache build and the branch build (methods added, removed, or renamed). To handle this,
pass `--test-files` with a list of changed test files. The leader will discard preresolved
entries for those files and re-discover their current test methods by loading them:

```bash
minitest-queue --queue redis://example.com run \
  --preresolved-tests cached_test_names.txt \
  --test-files changed_test_files.txt \
  -I. -Itest
```

Note: `--test-files` serves double duty. In plain lazy-load mode it provides the list of
test files to discover. In preresolved mode it acts as the reconciliation set.

**Stale entry handling**: Even with reconciliation, some preresolved entries may refer to
test methods that no longer exist (e.g., a helper file changed the set of dynamically
generated methods). By default, these cause an error on the worker. To skip them gracefully
as `Minitest::Skip` instead, set:

| Variable | Description |
|---|---|
| `CI_QUEUE_SKIP_STALE_TESTS=1` | Report stale preresolved entries as skips instead of errors. No CLI equivalent. |

**CLI flags:**

| Flag | Description |
|---|---|
| `--preresolved-tests FILE` | Read pre-computed test names from FILE. Implies `--lazy-load`. No env var equivalent. |
| `--test-files FILE` | In preresolved mode: reconciliation set of changed files to re-discover. |

If you'd like to centralize the error reporting you can do so with:

```bash
minitest-queue --queue redis://example.com --timeout 600 report
```

The runner also comes with a tool to investigate leaky tests:

```bash
minitest-queue --queue path/to/test_order.log --failing-test 'SomeTest#test_something' bisect -Itest test/**/*_test.rb
```

### RSpec [DEPRECATED]

The rspec-queue runner is deprecated. The minitest-queue runner continues to be supported and is actively being improved. At Shopify, we strongly recommend that new projects set up their test suite using Minitest rather than RSpec.

Assuming you use one of the supported CI providers, the command can be as simple as:

```bash
rspec-queue --queue redis://example.com
```

If you'd like to centralize the error reporting you can do so with:

```bash
rspec-queue --queue redis://example.com --timeout 600 --report
```

#### Limitations

Because of how `ci-queue` executes the examples, `before(:all)` and `after(:all)` hooks are not supported. `rspec-queue` will explicitly reject them.

## Releasing a New Version

After merging changes to `main`, follow these steps to release and propagate the update:

1. **Bump the version** in `ruby/lib/ci/queue/version.rb`:

    ```ruby
    VERSION = '0.XX.0'
    ```

2. **Update `Gemfile.lock`** by running `bundle install` in the `ruby/` directory (or manually updating the version string in `Gemfile.lock` if native dependencies prevent `bundle install`).

3. **Commit and merge** the version bump to `main`. ShipIt will automatically publish the gem to RubyGems.

4. **Update dependent apps/zones**: Any application that depends on `ci-queue` (e.g. via its `Gemfile`) needs to pick up the new version by running:

    ```bash
    bundle update ci-queue
    ```

    This updates the app's `Gemfile.lock` to reference the new `ci-queue` version. Commit the updated `Gemfile.lock` and deploy.

## Custom Redis Expiry

`ci-queue` expects the Redis server to have an [eviction policy](https://redis.io/docs/manual/eviction/#eviction-policies) of `allkeys-lru`.

You can also use `--redis-ttl` to set a custom expiration time for all CI Queue keys, this defaults to 8 hours (28,800 seconds)
