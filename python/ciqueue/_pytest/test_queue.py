import urlparse
import ciqueue
import ciqueue.distributed
import redis
import uritools


class InvalidRedisUrl(Exception):
    pass


def key_item(item):
    # TODO: discuss better identifier # pylint: disable=fixme
    return item.location[0] + '@' + item.location[2]


def parse_redis_args(query_string, tests_index):
    args = urlparse.parse_qs(query_string)

    if 'build' not in args or not args['build']:
        raise InvalidRedisUrl("Missing `build` parameter in {}"
                              .format(query_string))

    result = {
        'build_id': args['build'][0],
        'timeout': float(args.get('timeout', [0])[0]),
        'max_requeues': int(args.get('max_requeues', [0])[0]),
        'requeue_tolerance': float(args.get('requeue_tolerance', [0])[0]),
        'retry': int(args.get('retry', [0])[0]),
    }

    if tests_index:
        if 'worker' not in args or not args['worker']:
            raise InvalidRedisUrl("Missing `worker` parameter in {}"
                                  .format(query_string))
        result['worker_id'] = args['worker'][0]

    return result


def parse_redis_client_args(spec):
    query = urlparse.parse_qs(spec.query)

    result = {'host': spec.authority.split(':')[0],
              'db': int(spec.path[1:] or 0)}

    if spec.port:
        result['port'] = spec.port
    if 'socket_timeout' in query:
        result['socket_timeout'] = int(query['socket_timeout'][0])
    if 'socket_connect_timeout' in query:
        result['socket_connect_timeout'] = int(query['socket_connect_timeout'][0])
    if 'retry_on_timeout' in query:
        result['retry_on_timeout'] = bool(query['retry_on_timeout'][0])

    return result


def build_queue(queue_url, tests_index=None):
    spec = uritools.urisplit(queue_url)
    if spec.scheme == 'list':
        return ciqueue.Static(spec.path.split(':'))
    elif spec.scheme == 'file':
        return ciqueue.File(spec.path)
    elif spec.scheme == 'redis':
        redis_options = parse_redis_client_args(spec)
        redis_client = redis.StrictRedis(**redis_options)

        kwargs = parse_redis_args(spec.query, tests_index)
        retry = bool(kwargs['retry'])
        del kwargs['retry']

        klass = ciqueue.distributed.Worker
        if tests_index is None:
            klass = ciqueue.distributed.Supervisor
        queue = klass(tests=tests_index, redis=redis_client, **kwargs)
        if retry and tests_index:
            queue = queue.retry_queue()
        return queue
    else:
        raise "Unknown queue scheme: " + repr(spec.scheme)
