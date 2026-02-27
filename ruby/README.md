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
