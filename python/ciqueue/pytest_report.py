from __future__ import absolute_import
from __future__ import print_function
import dill
import pytest
from _pytest import runner
from ciqueue._pytest import utils


def pytest_addoption(parser):
    """Add command line options to py.test command."""
    parser.addoption('--queue', metavar='queue_url',
                     type=str, help='The queue url',
                     required=True)


def noop():
    pass


@pytest.hookimpl(trylast=True)
def pytest_collection_modifyitems(session, config, items):  # pylint: disable=unused-argument
    session.queue = utils.build_queue(session.config.getoption('queue'))
    session.queue.wait_for_workers(master_timeout=300)
    error_reports = session.queue.redis.hgetall(
        session.queue.key('error-reports')
    )
    for item in items:
        # mock out all test calls
        item.setup = noop
        item.runtest = noop
        item.teardown = noop

        # store the errors on setup/test/teardown to item.error_reports
        key = utils.key_item(item)
        if key in error_reports:
            item.error_reports = dill.loads(error_reports[key])
            for _, call_dict in item.error_reports.items():
                call_dict['excinfo'] = utils.swap_back_original(call_dict['excinfo'])


@pytest.hookimpl(tryfirst=True)
def pytest_runtest_makereport(item, call):
    # ensure all errors should come off the error-reports queue
    call.excinfo = None
    if hasattr(item, 'error_reports') and call.when in item.error_reports:
        call.__dict__ = item.error_reports[call.when]

        # This is needed to change the location of the failure
        # to point to the item definition, otherwise it will display
        # the location of where the skip exception was raised within pytest
        # https://github.com/pytest-dev/pytest/blob/master/_pytest/skipping.py#L263-L269
        if call.excinfo and call.excinfo.type == runner.Skipped:
            item._evalskip = True  # pylint: disable=protected-access
