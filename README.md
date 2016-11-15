# CI::Queue

[![Gem Version](https://badge.fury.io/rb/ci-queue.svg)](https://rubygems.org/gems/ci-queue)
[![Build Status](https://travis-ci.org/Shopify/ci-queue.svg?branch=master)](https://travis-ci.org/Shopify/ci-queue)

Distribute tests over many workers using a queue. 

## Why a queue?

One big problem with distributed test suites, is test imbalance. Meaning that one worker would spend 10 minutes while all the others are done after 1 minute.
There is algorithms available to balance perfectly your workers, but in practice your test performance tend to vary, and it's easier to consider tests as work unit in a queue and let workers pop them as fast as possible.

Another advantage is that if you lose workers along the way, using a queue the other workers can pick up the job, making you resilient to failures.

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

TODO: Write usage instructions here

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake test` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/Shopify/ci-queue.

## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).

