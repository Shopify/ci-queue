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

### RSpec

Assuming you use one of the supported CI providers, the command can be as simple as:

```bash
rspec-queue --queue redis://example.com
```

If you'd like to centralize the error reporting you can do so with:

```bash
rspec-queue --queue redis://example.com --timeout 600 --report
```

#### Limitations

Because of how `ci-queue` execute the examples, `before(:all)` and `after(:all)` hooks are not supported. `rspec-queue` will explicitly reject them.