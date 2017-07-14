from __future__ import absolute_import, print_function
import pytest
from ciqueue._pytest.utils import build_queue, key_item, swap_in_serializable
import cPickle


def pytest_addoption(parser):
    """Add command line options to py.test command."""
    parser.addoption('--queue', metavar='queue_url',
                     type=str, help='The queue url',
                     required=True)


class ItemIndex(object):

    def __init__(self, items):
        self.index = dict((key_item(i), i) for i in items)

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
        # TODO: Check if we could return a fake next test instead
        return 0

    def __getitem__(self, index):
        return None

    def __iter__(self):
        for test in self.queue:
            yield self.index[test]
            # TODO: Find proper hook for acknowledge / requeue
            self.queue.acknowledge(test)


class RedisReporter(object):

    def __init__(self, config, queue):
        self.config = config
        self.redis = queue.redis
        self.errors_key = queue.key('error-reports')

    # @staticmethod
    # def ensure_serializable(excinfo):
    #     def picklable(o):
    #         try:
    #             cPickle.dumps(o)
    #             return True
    #         except:
    #             return False

    #     if excinfo.type in SER:
    #         cls = SER[excinfo.type]
    #         tup = (cls, cls(*excinfo.value.args), excinfo.tb)
    #         excinfo = ExceptionInfo(tup)
    #     elif not picklable(excinfo):
    #         tup = (UnserializableException,
    #                UnserializableException("Actual Exception thrown on test node was %r" % excinfo.value),
    #                excinfo.tb)
    #         excinfo = ExceptionInfo(tup)
    #     return excinfo

    @pytest.hookimpl(tryfirst=True)
    def pytest_runtest_makereport(self, item, call):
        if call.excinfo:
            payload = call.__dict__.copy()
            payload['excinfo'] = swap_in_serializable(payload['excinfo'])

            if not hasattr(item, 'error_reports'):
                item.error_reports = {call.when: payload}
            else:
                item.error_reports[call.when] = payload

            self.redis.hset(
                self.errors_key,
                key_item(item),
                cPickle.dumps(item.error_reports))
        elif call.when == 'teardown' and not hasattr(item, 'error_reports'):
            self.redis.hdel(self.errors_key, key_item(item))


@pytest.hookimpl(trylast=True)
def pytest_collection_modifyitems(session, config, items):
    tests_index = ItemIndex(items)
    queue = build_queue(config.getoption('queue'), tests_index)
    if queue.distributed:
        config.pluginmanager.register(RedisReporter(config, queue))
    session.items = ItemList(tests_index, queue)
