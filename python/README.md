# ciqueue

`ciqueue` offers a collection of queue implementations to offer automatic distribution of tests on CI.

Using them requires an integration with the test framework runner.

## Why a queue?

One big problem with distributed test suites, is test imbalance. Meaning that one worker would spend 10 minutes while all the others are done after 1 minute.
There are algorithms available to balance perfectly your workers, but in practice your test performance tend to vary, and it's easier to consider tests as work unit in a queue and let workers pop them as fast as possible.

Another advantage is that if you lose workers along the way, using a queue the other workers can pick up the job, making you resilient to failures.

## Integrations

There is no integration for Python tests frameworks yet.

## Implementing a new integration

The reference implementation is the minitest one (Ruby).

### Basic Interface

All queue implementations are iterable, to pop unit of work off the queue, simply iterate over it.

The simplest integration could look like this:

```python
queue = ciqueue.Static(['tests/foo.py:test_foo', 'tests/foo.py:test_bar'])

for test_key in queue:
  result = run_one_test(test_key) # that part is heavily dependant on the test framework
  queue.acknowledge(test_key)
  reporter.record(result)
```

Once a test was ran, the integration should call `queue.acknowledge`, otherwise the test could be reassigned to another worker.


### Requeueing

The larger a test suite gets, the more likely it is to break because of a transient issue.
In such context, it might be desirable to try the test again on another worker.

To support requeueing, the integration can call `requeue` instead of `acknowledge`.
A complete integration should look like this:

```python
for test_key in queue:
  result = run_one_test(test_key) # that part is heavily dependant on the test framework

  # Only attempt to requeue if the test failed.
  # The method will return `False` if the test couldn't be requeued
  if result.failed and queue.requeue(test_name):
    # Since the test will run again, it should be marked as skipped, or a similar status
    result.failed = False
    result.skipped = True
    reporter.record(result)
  elsif queue.acknowledge(test_name) or !failed:
    # If the test was already acknowledged by another worker (we timed out)
    # Then we only record it if it was successful.
    reporter.record(result)
  end
```

## Implementations

`ciqueue` provides several queue implementations that can be swapped to implement many functionalities

### Common parameters

All implementations share the following constructor signature: `__init__(self, tests, max_requeues=0, requeue_tolerance=0)`

`tests`: should be a list of string. If you wish to randomize the test order (heavily recommended), you have to shuffle the list before you instantiate the queue.

`max_requeues`: defines how many times a single test can be requeued.

`requeue_tolerance`: defines how many requeues can be performed in total. Example, if your test suite contains 1000 tests, requeue_tolerance=0.05, means up to 5% of the suite can be requeued, so 50 tests.

### `ciqueue.Static`

The simplest implementation, mostly useful as a base class.

The tests are held in memory, and not distributed.

### `ciqueue.File`

Same as static, but takes a file path as first parameter. A common usage is to have a CI worker log all the tests it ran in a `test_order.log` file,
and feed that log to `ciqueue.File` to replay them in the exact same order.

### `ciqueue.distributed.Worker`

This ones takes a few more arguments:

`redis`: the Redis client to use.

`timeout`: the duration in seconds, after which a test, if not acknowledged, should be considered lost and re-assigned to another worker. Make sure this value is higher than your slowest test.

`worker_id`: a unique identifier for your worker. It MUST be different for all your workers in a build. Your CI system likely provides an useful environment variable for it, e.g. `CIRCLE_NODE_INDEX` or `BUILDKITE_PARALLEL_JOB`.

`build_id`: a unique identifier for your build. It MUST be the same for all workers in a build. Your system likely provides an useful environment variable for it, e.g. `CIRCLE_BUILD_NUM` or `BUILDKITE_BUILD_ID`.

This implementation will use the passed Redis client to distribute the tests among all the workers sharing the same `build_id`.

The first worker connected is automatically elected as the leader, and will push the test list inside Redis, once done all the workers will pop the tests one by one.
Which mean any worker can crash at any point, without compromising the entire build.

### `ciqueue.distributed.Worker.retry_queue`

Workers record the tests they ran in a Redis list, and this methods returns a new queue instance that will replay the test order.

It's useful for CI system that allow to retry a single job.

