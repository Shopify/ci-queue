import ciqueue
from urlparse import urlparse, parse_qs


def pytest_addoption(parser):
    """Add command line options to py.test command."""
    parser.addoption('--queue', metavar='queue_url',
                     type=str, help='The queue url',
                     required=True)


class ItemIndex(object):
  def __init__(self, items):
    self.index = dict((self._key(i), i) for i in items)

  def __len__(self):
    return len(self.index)

  def __getitem__(self, key):
    return self.index[key]

  def __iter__(self):
    return iter(self.index)

  def keys(self):
    return self.index.keys()

  def _key(self, item):
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

  def __iter__(self):
    for test in self.queue:
      yield self.index[test]
      self.queue.acknowledge(test) # TODO: Find proper hook for acknowledge / requeue


class InvalidRedisUrl(StandardError):
  pass


def parse_redis_args(query_string):
  args = parse_qs(query_string)

  if not 'worker' in args or not args['worker']:
    raise InvalidRedisUrl, "Missing `worker` parameter"

  if not 'build' in args or not args['build']:
    raise InvalidRedisUrl, "Missing `build` parameter"

  return {
    'worker_id': args['worker'][0],
    'build_id': args['build'][0],
    'timeout': float(args.get('timeout', [0])[0]),
    'max_requeues': int(args.get('max_requeues', [0])[0]),
    'requeue_tolerance': float(args.get('requeue_tolerance', [0])[0]),
  }


def build_queue(queue_url, tests_index):
  spec = urlparse(queue_url)
  if spec.scheme == 'list':
    return ciqueue.Static(spec.path.split(':'))
  elif spec.scheme == 'file':
    return ciqueue.File(spec.path)
  elif spec.scheme == 'redis':
    import redis
    redis_options = {'host': spec.hostname}
    if spec.port:
      redis_options['port'] = spec.port
    redis_client = redis.StrictRedis(**redis_options)

    kwargs = parse_redis_args(spec.query)
    return ciqueue.distributed.Worker(tests_index, redis=redis_client, **kwargs)
  else:
    raise "Unknown queue scheme: " + repr(spec.scheme)

def pytest_collection_modifyitems(session, config, items):
  tests_index = ItemIndex(items)
  queue = build_queue(config.getoption('queue'), tests_index)
  session.items = ItemList(tests_index, queue)

