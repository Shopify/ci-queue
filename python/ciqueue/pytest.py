from __future__ import absolute_import
from tblib import pickling_support
pickling_support.install()
import pickle
import pytest
from ciqueue.pytest_queue_url import build_queue


def pytest_addoption(parser):
    """Add command line options to py.test command."""
    parser.addoption('--queue', metavar='queue_url',
                     type=str, help='The queue url',
                     required=True)


class RedisReporter(object):

    def __init__(self, config, queue):
        self.config = config
        self.redis = queue.redis
        self.errors_key = queue.key('error-reports')

    def pytest_runtest_makereport(self, item, call):
        if call.excinfo:
            if not hasattr(item, 'error_reports'):
                item.error_reports = {call.when: call.__dict__}
            else:
                item.error_reports[call.when] = call.__dict__
            self.redis.hset(
                self.errors_key,
                ItemIndex.key(item),
                pickle.dumps(item.error_reports))
        elif call.when == 'teardown' and not hasattr(item, 'error_reports'):
            self.redis.hdel(self.errors_key, ItemIndex.key(item))


class ItemIndex(object):

    def __init__(self, items):
        self.index = dict((self.key(i), i) for i in items)

    def __len__(self):
        return len(self.index)

    def __getitem__(self, key):
        return self.index[key]

    def __iter__(self):
        return iter(self.index)

    def keys(self):
        return self.index.keys()

    @staticmethod
    def key(item):
        # TODO: discuss better identifier
        return item.location[0] + '@' + item.location[2]


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


@pytest.hookimpl(trylast=True)
def pytest_collection_modifyitems(session, config, items):
    tests_index = ItemIndex(items)
    queue = build_queue(config.getoption('queue'), tests_index)
    if queue.distributed:
        config.pluginmanager.register(RedisReporter(config, queue))
    session.items = ItemList(tests_index, queue)
