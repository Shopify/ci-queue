"""
This is the pytest plugin for running distributed tests.
Example usage (run on each node):
py.test -p ciqueue.pytest --queue redis://<host>:6379?worker=<worker_id>&build=<build_id>&retry=<n>
"""
from __future__ import absolute_import
from __future__ import print_function
from ciqueue._pytest import test_queue
from ciqueue._pytest import outcomes
import dill
import pytest
import redis

# pylint: disable=too-few-public-methods


def pytest_addoption(parser):
    """Add command line options to py.test command."""
    parser.addoption('--queue', metavar='queue_url',
                     type=str, help='The queue url',
                     required=True)


class ItemIndex(object):

    def __init__(self, items):
        self.index = dict((test_queue.key_item(i), i) for i in items)

    def __len__(self):
        return len(self.index)

    def __getitem__(self, key):
        return self.index[key]

    def __iter__(self):
        return iter(self.index)

    def keys(self):
        return self.index.keys()


class ItemList(object):

    def __init__(self, index, queue):
        self.index = index
        self.queue = queue

    def __len__(self):
        # HACK: Prevent pytest from grabbing the next test
        # TODO: Check if we could return a fake next test instead # pylint: disable=fixme
        return 0

    def __getitem__(self, index):
        return None

    def __iter__(self):
        for test in self.queue:
            self.queue.twriter.write('next item: {}\n'.format(test))
            yield self.index[test]
            # TODO: Find proper hook for acknowledge / requeue # pylint: disable=fixme
            self.queue.twriter.write('acking {}\n'.format(test))
            self.queue.acknowledge(test)
            self.queue.twriter.write('acked {}\n'.format(test))


class RedisReporter(object):

    def __init__(self, config, queue):
        self.config = config
        self.redis = queue.redis
        self.errors_key = queue.key('error-reports')
        self.twriter = config.get_terminal_writer()

    @pytest.hookimpl(tryfirst=True)
    def pytest_runtest_makereport(self, item, call):
        """This function hooks into pytest's reporting of test results, and pushes a failed test's error report
        onto the redis queue. A test can fail in any of the 3 call stages: setup, test, or teardown.
        This is captured by pushing a dict of {call_state: error} for each failed test."""

        self.twriter.write(call.when)
        if call.excinfo:
            payload = call.__dict__.copy()
            payload['excinfo'] = outcomes.swap_in_serializable(payload['excinfo'])

            if not hasattr(item, 'error_reports'):
                item.error_reports = {call.when: payload}
            else:
                item.error_reports[call.when] = payload

            try:
                self.redis.hset(
                    self.errors_key,
                    test_queue.key_item(item),
                    dill.dumps(item.error_reports))

            except redis.ConnectionError as error:
                self.twriter.write('redis error: {}\n'.format(error))
            except Exception as error:  # pylint: disable=broad-except
                self.twriter.write('error: %r' % error)

        # if the test passed, we remove it from the errors queue
        elif call.when == 'teardown' and not hasattr(item, 'error_reports'):
            self.twriter.write('deleting from errros: {}\n'.format(test_queue.key_item(item)))
            self.redis.hdel(self.errors_key, test_queue.key_item(item))
            self.twriter.write('deleted from errros: {}\n'.format(test_queue.key_item(item)))


@pytest.hookimpl(trylast=True)
def pytest_collection_modifyitems(session, config, items):
    """This function hooks into pytest's list of tests to run, and replaces
    those `items` with a redis test queue iterator."""
    tests_index = ItemIndex(items)
    queue = test_queue.build_queue(config.getoption('queue'), tests_index)
    if queue.distributed:
        queue.twriter = config.get_terminal_writer()
        config.pluginmanager.register(RedisReporter(config, queue))
    session.items = ItemList(tests_index, queue)
