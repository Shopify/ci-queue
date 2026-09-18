"""
This is the pytest plugin for running distributed tests.
Example usage (run on each node):
py.test -p ciqueue.pytest --queue redis://<host>:6379?worker=<worker_id>&build=<build_id>&retry=<n>
"""
from __future__ import absolute_import
from __future__ import print_function
from ciqueue._pytest import test_queue
from ciqueue._pytest import reports
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

    def record(self, item, test_failed):
        # Serialize before acknowledging so encoding errors cannot lose a failure.
        payload = reports.dumps(self.config, item.error_reports) if hasattr(item, 'error_reports') else None
        test_name = test_queue.key_item(item)
        # A late worker may replace an earlier failure only if it succeeded.
        if not self.queue.acknowledge(test_name) and test_failed:
            return False
        if payload is not None:
            self.redis.hset(self.errors_key, test_name, payload)
        else:
            self.redis.hdel(self.errors_key, test_name)
        return True

    def mark_as_skipped(self, report, item, msg):
        assert report.when == 'teardown'

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

        # Render retries locally; no exception or traceback objects go on the wire.
        path, lineno, _ = item.location
        report.outcome = 'skipped'
        report.longrepr = (path, (lineno or 0) + 1, msg)
        if hasattr(report, 'wasxfail'):
            del report.wasxfail

        # clear out the stats like the test never happened
        for key in ('passed', 'error', 'failed'):
            clear_out_stats(key)

        # rollback the testsfailed number like it never happened
        item.session.testsfailed -= sum(
            report.failed for when, report in item.error_reports.items() if when != 'teardown')

        # and clear out any state on the item like it never happened
        if hasattr(item, 'error_reports'):
            del item.error_reports

    @pytest.hookimpl(hookwrapper=True, tryfirst=True)
    def pytest_runtest_makereport(self, item, call):
        """Record final reports after pytest has applied skip and xfail outcomes."""
        result = yield
        report = result.get_result()
        if not report.passed:
            if not hasattr(item, 'error_reports'):
                item.error_reports = {}
            item.error_reports[report.when] = report

        if report.when == 'teardown':
            test_name = test_queue.key_item(item)
            test_failed = any(report.failed for report in getattr(item, 'error_reports', {}).values())

            # Only attempt to requeue if the test failed.
            # The method will return `False` if the test couldn't be requeued
            if test_failed and self.queue.requeue(test_name):
                self.mark_as_skipped(report, item, "WILL_RETRY")
                self.terminalwriter.write(' WILL_RETRY ', green=True)

            # Ignore a late failure if another worker already acknowledged the test.
            elif not self.record(item, test_failed):
                self.mark_as_skipped(report, item, "TIMED OUT")
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
