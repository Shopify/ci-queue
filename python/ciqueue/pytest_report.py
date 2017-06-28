import ciqueue.distributed
import redis
from ciqueue.pytest_queue_url import build_queue
from ciqueue.pytest import RedisReporter


def pytest_addoption(parser):
    """Add command line options to py.test command."""
    parser.addoption('--queue', metavar='queue_url',
                     type=str, help='The queue url',
                     required=True)


def pytest_collection(session, genitems=True):
    session.items = []
    session.queue = build_queue(session.config.getoption('queue'))
    session.queue.wait_for_workers()
    hook = session.config.hook
    hook.pytest_collection_finish(session=session)
    return session.items


def pytest_sessionfinish(session, exitstatus):
    reporter = RedisReporter(session.config, session.queue)
    print str(reporter)
    if len(session.queue):
        # Some tests weren't ran
        session.exitstatus = 7
    else:
        session.exitstatus = 0
