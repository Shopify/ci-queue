# CI::Queue

[![Gem Version](https://badge.fury.io/rb/ci-queue.svg)](https://rubygems.org/gems/ci-queue)
[![Tests](https://github.com/Shopify/ci-queue/workflows/Tests/badge.svg?branch=master)](https://github.com/Shopify/ci-queue/actions?query=workflow%3ATests)

Distribute tests over many workers using a queue. 

## Why a queue?

One big problem with distributed test suites, is test imbalance. Meaning that one worker would spend 10 minutes while all the others are done after 1 minute.
There are algorithms available to balance perfectly your workers, but in practice your test performance tend to vary, and it's easier to consider tests as work unit in a queue and let workers pop them as fast as possible.

Another advantage is that if you lose workers along the way, using a queue the other workers can pick up the job, making you resilient to failures.

## How does it work?

Each workers first participate in a leader election, the elected leader will then populate the queue with the list of tests to run.
Once the queue is initialized, all workers including the leader will reserve tests and work them on until the queue is empty.

If a worker were to die, its reserved work load will be put back into the queue to be picked up by it's surviving siblings.

Additionally, a separate process can be started to centralize the error reporting, that process will wait for the queue to be empty before exiting.

## What are requeues?

When working on big test suites, it's not uncommon for a few tests to fail intermittently, either because they are inherently flaky,
or because they are sensible to other tests modifying some global state (leaky tests).

In this context, it is useful to have mitigation measures so that these intermittent failures don't cause unrelated builds to fail until the root cause is addressed.

This is why `ci-queue` optionally allows to put failed tests back into the queue to retry them on another worker, to ensure the failure is consistent.

## Installation and usage

Two implementations are provided, please refer to the respective documentations:

  - [Python](python/)
  - [Ruby](ruby/)

## Redis Requirements

`ci-queue` expects the Redis server to have an [eviction policy](https://redis.io/docs/manual/eviction/#eviction-policies) of `allkeys-lru`.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/Shopify/ci-queue.

## License

The code is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).

