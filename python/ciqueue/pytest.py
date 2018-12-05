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
from _pytest import terminal

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
        if hasattr(self.terminalreporter, '_get_progress_information_message'):
            self.__replace_progress_message()
        self.terminalwriter = config.get_terminal_writer()
        self.logxml = config._xml if hasattr(config, '_xml') else None  # pylint: disable=protected-access

    def __replace_progress_message(self):  # pylint: disable=no-self-use
        def _get_progress(self):  # pylint: disable=unused-argument
            return ''

        terminal.TerminalReporter._get_progress_information_message = _get_progress  # pylint: disable=protected-access

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

    def mark_as_skipped(self, call, item, msg):
        assert call.when == 'teardown'

        stats = self.terminalreporter.stats

        def clear_out_stats(key):
            if key in stats:
                new_stats = []
                for i in stats[key]:
                    if i.nodeid != item.nodeid:
                        new_stats.append(i)
                    elif self.logxml:
                        xmlkey = 'failure' if key == 'failed' else key
                        self.logxml.stats[xmlkey] -= 1
                stats[key] = new_stats
                if not stats[key]:
                    del stats[key]

        # remove the failure/error from logxml
        if self.logxml:
            self.logxml.node_reporters_ordered[-1].nodes = []

        # the call is converted to a skip
        call.excinfo = outcomes.skipped_excinfo(item, msg)

        # clear out the stats like the test never happened
        for key in ('passed', 'error', 'failed'):
            clear_out_stats(key)

        # rollback the testsfailed number like it never happened
        item.session.testsfailed -= len([v for k, v in item.error_reports.items()
                                         if not issubclass(v['excinfo'].type, outcomes.Skipped) and k != 'teardown'])

        # and clear out any state on the item like it never happened
        if hasattr(item, 'error_reports'):
            del item.error_reports

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
                self.mark_as_skipped(call, item, "WILL_RETRY")
                self.terminalwriter.write(' WILL_RETRY ', green=True)

            # If the test was already acknowledged by another worker (we timed out)
            # Then we only record it if it was successful.
            elif self.queue.acknowledge(test_name) or not test_failed:
                self.record(item)

            # The test timed out and failed, mark it as skipped so that it doesn't
            # fail the build
            else:
                self.mark_as_skipped(call, item, "TIMED OUT")
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

    items = iter(session.items)

    # Pull two tests at a time to provide nextitem to pytest, which
    # allows for optimal teardown of fixtures.
    try:
        item = next(items)
    except StopIteration:
        # There were no tests queued.
        return True

    while True:
        try:
            nextitem = next(items)
        except StopIteration:
            # There are no more tests -- finish our final one.
            item.config.hook.pytest_runtest_protocol(item=item, nextitem=None)
            break

        item.config.hook.pytest_runtest_protocol(item=item, nextitem=nextitem)
        item = nextitem

        if session.shouldstop:
            raise session.Interrupted(session.shouldstop)

    return True
