from __future__ import absolute_import

import pytest
import pickle
from ciqueue._pytest.utils import build_queue, key_item, DESER


def pytest_addoption(parser):
    """Add command line options to py.test command."""
    parser.addoption('--queue', metavar='queue_url',
                     type=str, help='The queue url',
                     required=True)


def noop():
    pass


@pytest.hookimpl(trylast=True)
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

        key = key_item(item)
        if key in error_reports:
            item.error_reports = pickle.loads(error_reports[key])


@pytest.hookimpl(tryfirst=True)
def pytest_runtest_makereport(item, call):
    # all errors should come off the error-reports queue
    call.excinfo = None
    if hasattr(item, 'error_reports') and call.when in item.error_reports:
        new_d = item.error_reports[call.when]
        if new_d['excinfo'].type in DESER:
            tipe = DESER[new_d['excinfo'].type]
            tup = (tipe, tipe(new_d['excinfo'].value.args), new_d['excinfo'].tb)
            new_d['excinfo'] = type(new_d['excinfo'])(tup)
        call.__dict__ = new_d
