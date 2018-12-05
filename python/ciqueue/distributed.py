import os
import time
import math
import redis

from past.builtins import xrange  # pylint: disable=redefined-builtin,import-modules-only

from ciqueue import static


class LostMaster(Exception):
    pass


class Base(object):

    def __init__(self, redis, build_id):
        self.redis = redis
        self.build_id = str(build_id)
        self.is_master = False
        self.total = None
        self._scripts = {}

    def key(self, *args):
        return ':'.join(['build', self.build_id] + [str(i) for i in args])

    def wait_for_master(self, timeout=10):
        if self.is_master:
            return True

        for _ in xrange(timeout * 10 + 1):
            master_status = self._master_status()
            if master_status in ['ready', 'finished']:
                return True
            time.sleep(0.1)

        raise LostMaster(
            "The master worker is still `" +
            repr(master_status) +
            "` after {} seconds waiting.".format(timeout))

    def _master_status(self):
        raw = self.redis.get(self.key('master-status'))
        return raw.decode() if raw else None

    def __len__(self):
        transaction = self.redis.pipeline(transaction=True)
        transaction.llen(self.key('queue'))
        transaction.zcard(self.key('running'))
        return sum(transaction.execute())

    @property
    def progress(self):
        return self.total - len(self)


class Worker(Base):
    distributed = True

    def __init__(self, tests, worker_id, redis, build_id,  # pylint: disable=too-many-arguments
                 timeout, max_requeues=0, requeue_tolerance=0):
        super(Worker, self).__init__(redis=redis, build_id=build_id)
        self.timeout = timeout
        self.total = len(tests)
        self.max_requeues = max_requeues
        self.global_max_requeues = math.ceil(len(tests) * requeue_tolerance)
        self.worker_id = worker_id
        self.shutdown_required = False
        self._push(tests)

    def __iter__(self):
        def poll():
            while not self.shutdown_required and self.redis.llen(self.key('queue')):
                test = self._reserve()
                if test:
                    yield test.decode()
                else:
                    time.sleep(0.05)

        try:
            self.wait_for_master()
            for i in poll():
                yield i
        except redis.ConnectionError:
            pass

    def shutdown(self):
        self.shutdown_required = True

    def acknowledge(self, test):
        return self._eval_script(
            'acknowledge',
            keys=[self.key('running'), self.key('processed')],
            args=[test],
        ) == 1

    def requeue(self, test, offset=42):
        if not (self.max_requeues > 0 and self.global_max_requeues > 0.0):
            return False

        return self._eval_script(
            'requeue',
            keys=[
                self.key('processed'),
                self.key('requeues-count'),
                self.key('queue'),
                self.key('running')],
            args=[self.max_requeues, self.global_max_requeues, test, offset],
        ) == 1

    def retry_queue(self):
        tests = [v.decode() for v in self.redis.lrange(
            self.key('worker', self.worker_id, 'queue'), 0, -1)]
        tests.reverse()
        return Retry(
            tests,
            redis=self.redis,
            build_id=self.build_id,
        )

    def _push(self, tests):
        def push(tests):
            transaction = self.redis.pipeline(transaction=True)
            transaction.lpush(self.key('queue'), *tests)
            transaction.set(self.key('total'), self.total)
            transaction.set(self.key('master-status'), 'ready')
            transaction.execute()

        try:
            self.is_master = self.redis.setnx(
                self.key('master-status'),
                'setup'
            )
            if self.is_master:
                push(tests)

            self._register()
        except redis.ConnectionError:
            if self.is_master:
                raise

    def _register(self):
        self.redis.sadd(self.key('workers'), self.worker_id)

    def _reserve(self):
        return self._try_to_reserve_lost_test() or self._try_to_reserve_test()

    def _try_to_reserve_lost_test(self):
        if self.timeout:
            return self._eval_script(
                'reserve_lost',
                keys=[
                    self.key('running'),
                    self.key('completed'),
                    self.key(
                        'worker',
                        self.worker_id,
                        'queue')],
                args=[time.time(), self.timeout],
            )

    def _try_to_reserve_test(self):
        return self._eval_script(
            'reserve',
            keys=[
                self.key('queue'),
                self.key('running'),
                self.key('processed'),
                self.key('worker', self.worker_id, 'queue'),
            ],
            args=[
                time.time(),
            ],
        )

    def _eval_script(self, script_name, keys=None, args=None):
        keys = keys or []
        args = args or []
        if script_name not in self._scripts:
            filename = 'redis/' + script_name + '.lua'

            path = os.path.join(os.path.dirname(__file__), '../../', filename)
            if not os.path.exists(path):
                path = os.path.join(os.path.dirname(__file__), filename)

            with open(path) as script_file:
                self._scripts[script_name] = self.redis.register_script(
                    script_file.read())

        script = self._scripts[script_name]
        return script(keys=keys, args=args)


class Supervisor(Base):

    def __init__(self, redis, build_id, *args, **kwargs):  # pylint: disable=unused-argument
        super(Supervisor, self).__init__(redis=redis, build_id=build_id)

    def _push(self, tests):
        pass

    def wait_for_workers(self, master_timeout=None):
        if not self.wait_for_master(timeout=master_timeout):
            return False

        while len(self):  # pylint: disable=len-as-condition
            time.sleep(0.1)

        return True


class Retry(static.Static):
    distributed = True

    def __init__(self, tests, redis, build_id):
        super(Retry, self).__init__(tests)
        self.redis = redis
        self.build_id = build_id

    def key(self, *args):
        return ':'.join(['build', self.build_id] + map(str, args))
