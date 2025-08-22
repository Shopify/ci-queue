# ciqueue

`ciqueue` offers a collection of queue implementations to offer automatic distribution of tests on CI.

Using them requires an integration with the test framework runner.

## Why a queue?

One big problem with distributed test suites, is test imbalance. Meaning that one worker would spend 10 minutes while all the others are done after 1 minute.
There are algorithms available to balance perfectly your workers, but in practice your test performance tend to vary, and it's easier to consider tests as work unit in a queue and let workers pop them as fast as possible.

Another advantage is that if you lose workers along the way, using a queue the other workers can pick up the job, making you resilient to failures.

## Installation

Add this to your `Cargo.toml`:

```toml
[dependencies]
ci-queue-core = "0.1.0"
```

## Integrations

### Playwright

There is a Playwright integration that can be used as follows.
To start up the workers which execute the tests, run a command like the following on each worker node:

```bash
playwright-queue --queue redis://<host>:6379 --build <build_id> run --worker <worker_id> --max-requeues <n> --requeue-tolerance <percentage>
```

<!--
Then, to get a summary report of all the tests, run the following on another node:
```bash
playwright-queue --queue redis://<host>:6379 --build <build_id> report
``` -->

## Implementing a new integration

The reference implementation is the minitest one (Ruby).

### Basic Interface

All queue implementations implement the `Queue` trait and are iterable. To pop units of work off the queue, simply iterate over it.

The simplest integration could look like this:

```rust
use ci_queue_core::{StaticQueue, QueueConfig};

let tests = vec![
    "tests/foo.rs::test_foo".to_string(),
    "tests/bar.rs::test_bar".to_string(),
];
let config = QueueConfig::default();
let mut queue = StaticQueue::new(tests, config);

while let Some(test) = queue.next() {
    let result = run_one_test(&test); // that part is heavily dependent on the test framework
    queue.acknowledge(&test);
    reporter.record(result);
}
```

Once a test was ran, the integration should call `queue.acknowledge`, otherwise the test could be reassigned to another worker.

### Requeueing

The larger a test suite gets, the more likely it is to break because of a transient issue.
In such context, it might be desirable to try the test again on another worker.

To support requeueing, the integration can call `requeue` instead of `acknowledge`.
A complete integration should look like this:

```rust
while let Some(test) = queue.next() {
    let result = run_one_test(&test); // that part is heavily dependent on the test framework

    // Only attempt to requeue if the test failed.
    // The method will return `false` if the test couldn't be requeued
    if result.failed && queue.requeue(&test) {
        // Since the test will run again, it should be marked as skipped, or a similar status
        result.failed = false;
        result.skipped = true;
        reporter.record(result);
    } else if queue.acknowledge(&test) || !result.failed {
        // If the test was already acknowledged by another worker (we timed out)
        // Then we only record it if it was successful.
        reporter.record(result);
    }
}
```

## Implementations

`ciqueue` provides several queue implementations that can be swapped to implement many functionalities

### Common parameters

All implementations share the following constructor parameters:

`tests`: should be a vector of strings. If you wish to randomize the test order (heavily recommended), you have to shuffle the list before you instantiate the queue.

`max_requeues`: defines how many times a single test can be requeued.

`requeue_tolerance`: defines how many requeues can be performed in total. Example, if your test suite contains 1000 tests, requeue_tolerance=0.05, means up to 5% of the suite can be requeued, so 50 tests.

### `ci_queue_core::StaticQueue`

The simplest implementation, mostly useful as a base class.

The tests are held in memory, and not distributed.

### `ci_queue_core::distributed::Worker`

This one takes a few more arguments:

`redis_url`: the Redis connection URL to use.

`timeout`: the duration in seconds, after which a test, if not acknowledged, should be considered lost and re-assigned to another worker. Make sure this value is higher than your slowest test.

`worker_id`: a unique identifier for your worker. It MUST be different for all your workers in a build. Your CI system likely provides a useful environment variable for it, e.g. `CIRCLE_NODE_INDEX` or `BUILDKITE_PARALLEL_JOB`.

`build_id`: a unique identifier for your build. It MUST be the same for all workers in a build. Your system likely provides a useful environment variable for it, e.g. `CIRCLE_BUILD_NUM` or `BUILDKITE_BUILD_ID`.

This implementation will use the passed Redis client to distribute the tests among all the workers sharing the same `build_id`.

The first worker connected is automatically elected as the leader, and will push the test list inside Redis, once done all the workers will pop the tests one by one.
Which means any worker can crash at any point, without compromising the entire build.

<!-- ### `ci_queue_core::distributed::Worker.retry_queue`

Workers record the tests they ran in a Redis list, and this method returns a new queue instance that will replay the test order.

It's useful for CI systems that allow to retry a single job. -->
