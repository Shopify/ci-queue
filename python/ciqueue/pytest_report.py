"""
This is the pytest plugin for reporting on the results of the distributed tests.
Example usage (run on each node):
py.test -p ciqueue.pytest_report --queue redis://<host>:6379?build=<build_id>&retry=<n>
"""

from __future__ import absolute_import
from __future__ import print_function
import pytest
from ciqueue._pytest import test_queue
from ciqueue._pytest import reports


def pytest_addoption(parser):
    """Add command line options to py.test command."""
    parser.addoption('--queue', metavar='queue_url',
                     type=str, help='The queue url',
                     required=True)


def noop():
    pass


@pytest.hookimpl(trylast=True)
def pytest_collection_modifyitems(session, config, items):  # pylint: disable=unused-argument
    """this function hooks into pytest's list of tests to run, converts all of them into
    noop's, and downloads the result of each test run from the redis queue. Test errors are
    attached to each test's `error_reports` field."""
    session.queue = test_queue.build_queue(session.config.getoption('queue'))
    session.queue.wait_for_workers(master_timeout=300)
    error_reports = {k.decode(): v
                     for k, v
                     in session.queue.redis.hgetall(session.queue.key('error-reports')).items()}

    for item in items:
        # mock out all test calls
        item.setup = noop
        item.runtest = noop
        item.teardown = noop

        # store the errors on setup/test/teardown to item.error_reports
        key = test_queue.key_item(item)
        if key in error_reports:
            item.error_reports = reports.loads(config, error_reports[key], key)


@pytest.hookimpl(hookwrapper=True, tryfirst=True)
def pytest_runtest_makereport(item, call):
    """Replay the worker's final outcome after local skip/xfail hooks have run."""
    call.excinfo = None
    result = yield
    if hasattr(item, 'error_reports') and call.when in item.error_reports:
        result.force_result(item.error_reports[call.when])
    elif hasattr(item, 'error_reports') and call.when == 'teardown':
        # JUnit finalizes metadata on teardown, even when only an earlier phase failed.
        previous = item.error_reports.get('call') or item.error_reports['setup']
        report = result.get_result()
        report.user_properties = previous.user_properties
        report.sections = previous.sections
