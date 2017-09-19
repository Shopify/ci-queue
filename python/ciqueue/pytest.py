"""
This is the pytest plugin for running distributed tests.
Example usage (run on each node):
py.test -p ciqueue.pytest --queue redis://<host>:6379?worker=<worker_id>&build=<build_id>&retry=<n>
"""
from __future__ import absolute_import
from __future__ import print_function
import zlib
from ciqueue._pytest import test_queue
from ciqueue._pytest import outcomes
import dill
import pytest

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

    def __getitem__(self, index):
        return None

    def __iter__(self):
        for test in self.queue:
            yield self.index[test]


class RedisReporter(object):

    def __init__(self, config, queue):
        self.config = config
        self.queue = queue
        self.redis = queue.redis
        self.errors_key = queue.key('error-reports')
        self.terminalreporter = config.pluginmanager.get_plugin('terminalreporter')
        self.terminalwriter = config.get_terminal_writer()

    def record(self, item):
        # if the test passed, we remove it from the errors queue
        # otherwise we add it
        if hasattr(item, 'error_reports'):
            self.redis.hset(
                self.errors_key,
                test_queue.key_item(item),
                zlib.compress(dill.dumps(item.error_reports)))
        else:
            self.redis.hdel(self.errors_key, test_queue.key_item(item))

    @pytest.hookimpl(tryfirst=True)
    def pytest_runtest_makereport(self, item, call):
        """This function hooks into pytest's reporting of test results, and pushes a failed test's error report
        onto the redis queue. A test can fail in any of the 3 call stages: setup, test, or teardown.
        This is captured by pushing a dict of {call_state: error} for each failed test."""
        if call.excinfo:
            payload = call.__dict__.copy()
            payload['excinfo'] = outcomes.swap_in_serializable(payload['excinfo'])

            if not hasattr(item, 'error_reports'):
                item.error_reports = {call.when: payload}
            else:
                item.error_reports[call.when] = payload

        if call.when == 'teardown':
            test_name = test_queue.key_item(item)
            test_failed = outcomes.failed(item)

            # Only attempt to requeue if the test failed.
            # The method will return `False` if the test couldn't be requeued
            if test_failed and self.queue.requeue(test_name):
                outcomes.mark_as_skipped(call, item, self.terminalreporter.stats, "WILL_RETRY")
                self.terminalwriter.write(' WILL_RETRY ', green=True)

            # If the test was already acknowledged by another worker (we timed out)
            # Then we only record it if it was successful.
            elif self.queue.acknowledge(test_name) or not test_failed:
                self.record(item)

            # The test timed out and failed, mark it as skipped so that it doesn't
            # fail the build
            else:
                outcomes.mark_as_skipped(call, item, self.terminalreporter.stats, "TIMED OUT")
                self.terminalwriter.write(' TIMED OUT ', green=True)


@pytest.hookimpl(tryfirst=True)
def pytest_runtestloop(session):
    if (session.testsfailed and
            not session.config.option.continue_on_collection_errors):
        raise session.Interrupted(
            "%d errors during collection" % session.testsfailed)

    if session.config.option.collectonly:
        return True

    config = session.config
    tests_index = ItemIndex(session.items)
    queue = test_queue.build_queue(config.getoption('queue'), tests_index)
    if queue.distributed:
        config.pluginmanager.register(RedisReporter(config, queue))
    session.items = ItemList(tests_index, queue)

    for item in session.items:
        item.config.hook.pytest_runtest_protocol(item=item, nextitem=None)
        if session.shouldstop:
            raise session.Interrupted(session.shouldstop)
    return True
