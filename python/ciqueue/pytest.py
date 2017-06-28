from StringIO import StringIO
import py.io
import ciqueue
import ciqueue.distributed
from ciqueue.pytest_queue_url import build_queue


def pytest_addoption(parser):
    """Add command line options to py.test command."""
    parser.addoption('--queue', metavar='queue_url',
                     type=str, help='The queue url',
                     required=True)


class RedisReporter(object):
    class TestCase(object):
        def __init__(self):
            self.passed = False
            self.failed = False
            self.messages = []

        def append_pass(self, report):
            self.passed = True

        def append_failure(self, report):
            self.failed = True
            self.messages.append(self._serialize(report))

        def __str__(self):
            if self.failed:
                return "\n".join(self.messages)
            return ''

        def _serialize(self, report):
            io = StringIO()
            io.isatty = lambda: True
            tw = py.io.TerminalWriter(file=io)
            report.longrepr.toterminal(tw)
            io.seek(0)
            return io.read()

    def __init__(self, config, queue):
        self.config = config
        self.redis = queue.redis
        self.errors_key = queue.key('error-reports')
        self.reporter = self.TestCase()

    def __str__(self):
        errors = self.redis.hgetall(self.errors_key)
        if errors:
            return "\n".join(errors.values())
        return ''

    def finalize(self, report):
        old_reporter = self.reporter
        self.reporter = self.TestCase()

        if old_reporter.passed:
            self.redis.hdel(self.errors_key, ItemIndex.key(report))
        elif old_reporter.failed:
            self.redis.hset(
                self.errors_key,
                ItemIndex.key(report),
                str(old_reporter))

    def pytest_runtest_logreport(self, report):
        if report.passed:
            if report.when == "call":  # ignore setup/teardown
                self.reporter.append_pass(report)
        elif report.failed:
            self.reporter.append_failure(report)

        if report.when == "teardown":
            self.finalize(report)


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


def pytest_collection_modifyitems(session, config, items):
    tests_index = ItemIndex(items)
    queue = build_queue(config.getoption('queue'), tests_index)
    if queue.distributed:
        config.pluginmanager.register(RedisReporter(config, queue))
    session.items = ItemList(tests_index, queue)
