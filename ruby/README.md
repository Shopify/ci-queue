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

Lazy loading and streaming are currently supported only by `minitest-queue` (not `rspec-queue`).

To reduce worker memory usage, you can enable lazy loading so test files are loaded on-demand:

```bash
minitest-queue --queue redis://example.com --lazy-load run -Itest test/**/*_test.rb
```

You can tune streaming with `--lazy-load-stream-batch-size` (default: 5000) and `--lazy-load-stream-timeout` (default 300s).

Environment variables:

- `CI_QUEUE_LAZY_LOAD=1`
- `CI_QUEUE_LAZY_LOAD_STREAM_BATCH_SIZE=10000`
- `CI_QUEUE_LAZY_LOAD_STREAM_TIMEOUT=300`
- `CI_QUEUE_LAZY_LOAD_TEST_HELPERS=test/test_helper.rb`

Backward-compatible aliases still work:

- `CI_QUEUE_STREAM_BATCH_SIZE`
- `CI_QUEUE_STREAM_TIMEOUT`
- `CI_QUEUE_TEST_HELPERS`

When enabled, file loading stats are printed at the end of the run if debug is enabled.

#### Preresolved test names (opt-in)

For large test suites, you can pre-compute the full list of test names on a stable branch and
reuse it on feature branches. This avoids loading all test files on every worker:

```bash
minitest-queue --queue redis://example.com run \
  --preresolved-tests test_names.txt \
  -I. -Itest
```

The file format is one test per line: `TestClass#method_name|path/to/test_file.rb`.
The leader streams entries directly to Redis; workers load test files on-demand.

**Reconciliation with `--test-files`**: When combined with `--test-files`, entries whose
file path appears in that list are skipped and the files are lazily re-discovered. This
handles cases where test methods have been added, removed, or renamed since the cache was built:

```bash
minitest-queue --queue redis://example.com run \
  --preresolved-tests cached_test_names.txt \
  --test-files changed_test_files.txt \
  -I. -Itest
```

**Stale entry handling**: If a preresolved entry refers to a test method that no longer exists
(e.g., it was renamed or removed and not caught by reconciliation), by default the worker will
report an error. Set `CI_QUEUE_SKIP_STALE_TESTS=1` to skip these entries gracefully instead:

- `CI_QUEUE_SKIP_STALE_TESTS=1` — report stale entries as Minitest skips instead of errors

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
