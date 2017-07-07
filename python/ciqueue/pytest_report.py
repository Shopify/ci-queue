from __future__ import absolute_import

import pytest
import pickle
from ciqueue.pytest_queue_url import build_queue
from ciqueue.pytest import ItemIndex


def pytest_addoption(parser):
    """Add command line options to py.test command."""
    parser.addoption('--queue', metavar='queue_url',
                     type=str, help='The queue url',
                     required=True)


def noop():
    pass


@pytest.hookimpl(tryfirst=True)
def pytest_collection_modifyitems(session, config, items):
    session.queue = build_queue(session.config.getoption('queue'))
    session.queue.wait_for_workers(master_timeout=300)
    error_reports = session.queue.redis.hgetall(
        session.queue.key('error-reports')
    )
    for item in items:
        item.setup = noop
        item.runtest = noop
        item.teardown = noop
        key = ItemIndex.key(item)
        if key in error_reports:
            item.error_reports = pickle.loads(error_reports[key])


def pytest_runtest_makereport(item, call):
    if hasattr(item, 'error_reports') and call.when in item.error_reports:
        call.__dict__ = item.error_reports[call.when]
