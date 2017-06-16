import os
import time
import math
from redis import ConnectionError

from ciqueue.static import Static


class LostMaster(StandardError):
  pass


class Base(object):
  def __init__(self, redis, build_id):
    self.redis = redis
    self.build_id = str(build_id)
    self.is_master = False
    self._scripts = {}

  def key(self, *args):
    return ':'.join(['build', self.build_id] + map(str, args))

  def wait_for_master(self, timeout=10):
    if self.is_master:
      return True

    for i in range(timeout * 10 + 1):
      master_status = self._master_status()
      if master_status in ['ready', 'finished']:
        return True
      time.sleep(0.1)

    raise LostMaster("The master worker is still `" + repr(master_status) + "` after 10 seconds waiting.")

  def _master_status(self):
    return self.redis.get(self.key('master-status'))

  def __len__(self):
    transaction = self.redis.pipeline(transaction=True)
    transaction.llen(self.key('queue'))
    transaction.zcard(self.key('running'))
    return sum(transaction.execute())

  @property
  def progress(self):
    return self.total - len(self)


class Worker(Base):
  def __init__(self, tests, worker_id, redis, build_id, timeout, max_requeues=0, requeue_tolerance=0):
    super(Worker, self).__init__(redis=redis, build_id=build_id)
    self.timeout = timeout
    self.total = len(tests)
    self.max_requeues = max_requeues
    self.global_max_requeues = math.ceil(len(tests) * requeue_tolerance)
    self.worker_id = worker_id
    self.shutdown_required = False
    self._push(tests)

  def __iter__(self):
    self.wait_for_master()

    while not self.shutdown_required and len(self):
      test = self._reserve()
      if test:
        yield test
      else:
        return
        time.sleep(0.05)

  def shutdown(self):
    self.shutdown_required = True

  def acknowledge(self, test):
    return self._eval_script(
      'acknowledge',
      keys=[self.key('running'), self.key('processed')],
      args=[test],
    ) == 1

  def requeue(self, test, offset=42):
    return self._eval_script(
      'requeue',
      keys=[self.key('processed'), self.key('requeues-count'), self.key('queue'), self.key('running')],
      args=[self.max_requeues, self.global_max_requeues, test, offset],
    ) == 1

  def retry_queue(self):
    tests = self.redis.lrange(self.key('worker', self.worker_id, 'queue'), 0, -1)
    tests.reverse()
    return Static(tests)

  def _push(self, tests):
    try:
      self.is_master = self.redis.setnx(self.key('master-status'), 'setup')
      if self.is_master:
        transaction = self.redis.pipeline(transaction=True)
        transaction.lpush(self.key('queue'), *tests)
        transaction.set(self.key('total'), self.total)
        transaction.set(self.key('master-status'), 'ready')
        transaction.execute()

      self._register()
    except ConnectionError:
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
        keys=[self.key('running'), self.key('completed'), self.key('worker', self.worker_id, 'queue')],
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

  def _eval_script(self, script_name, keys=[], args=[]):
    if not script_name in self._scripts:
      # TODO(byroot): Handle packaging of scripts inside the egg
      relative_path = '../../redis/' + script_name + '.lua'
      path = os.path.join(os.path.dirname(__file__), relative_path)
      with open(path) as f:
        self._scripts[script_name] = self.redis.register_script(f.read())
    
    script = self._scripts[script_name]
    return script(keys=keys, args=args)
