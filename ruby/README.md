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

Additionally you can configure the requeue settings (see main README) with `--max-requeues` and `--requeue-tolerance`. Worker-health circuit breakers are available through `--max-consecutive-failures` and `--max-consecutive-requeues`.

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

### Parallel worker metadata

Each recorded result is stamped, in the process that ran the test, with:

- `parallel_worker_pid`: the pid of the worker process at result creation.
- `parallel_worker_test_index`: a 0-based, per-process monotonic counter incremented as each test runs (requeued executions get their own index).
- `parallel_worker_id`: an identifier injected by the embedding environment (e.g. a Rails parallel-testing worker number); `nil` when not applicable.

All three fields are included (nil-safe) in `log/test_data.json` emitted by the test data reporter, making per-worker-process execution order reconstructable downstream (`PARTITION BY parallel_worker_id, parallel_worker_pid ORDER BY parallel_worker_test_index`).

The worker id can be provided either programmatically or via the environment:

```ruby
Minitest::Queue.parallel_worker_id = 3
```

Stamping is first-writer-wins. When ci-queue runs tests in-process (the normal
`minitest-queue` flow), results are stamped automatically as they are recorded.
Embedding environments that run tests in forked workers and transport results to
another process (e.g. over DRb to a central reporting server) must stamp in the
worker **before** sending:

```ruby
# in the forked worker, after running the test and before the DRb send
Minitest::Queue.stamp_parallel_worker_metadata(result)
```

Otherwise the automatic stamp during reporting would capture the reporting
process's pid and an arrival-order index interleaved across workers. Pre-stamped
results pass through reporting untouched.

| Variable | Description |
|---|---|
| `CI_QUEUE_PARALLEL_WORKER_ID=N` | Sets `parallel_worker_id` for results produced by this process. The setter takes precedence. |

### Worker circuit breakers

Both runners support two independent, disabled-by-default circuit breakers:

- `--max-consecutive-failures MAX` stops a worker after `MAX` consecutive final test failures.
- `--max-consecutive-requeues MAX` stops a worker after `MAX` consecutive failures were accepted for requeueing.

The requeue count is local to each worker and resets whenever that worker produces any non-requeued result, including a pass, skip, ignored flaky result, or final failure. An accepted requeue neither increments nor resets the consecutive-final-failure count. Requeue attempts rejected because of an ownership race or an exhausted retry budget follow the final-failure path and do not increment the requeue count.

For example:

```bash
minitest-queue --max-consecutive-requeues 10 --queue redis://example.com run test/**/*_test.rb
rspec-queue --max-consecutive-requeues 10 --queue redis://example.com
```

The breaker can also be configured programmatically:

```ruby
CI::Queue::Configuration.new(max_consecutive_requeues: 10)
# or
config.max_consecutive_requeues = 10
```

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
