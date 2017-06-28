import ciqueue
import redis
from urlparse import urlparse, parse_qs


class InvalidRedisUrl(Exception):
    pass


def parse_redis_args(query_string):
    args = parse_qs(query_string)

    if not 'worker' in args or not args['worker']:
        raise InvalidRedisUrl("Missing `worker` parameter")

    if not 'build' in args or not args['build']:
        raise InvalidRedisUrl("Missing `build` parameter")

    return {
        'worker_id': args['worker'][0],
        'build_id': args['build'][0],
        'timeout': float(args.get('timeout', [0])[0]),
        'max_requeues': int(args.get('max_requeues', [0])[0]),
        'requeue_tolerance': float(args.get('requeue_tolerance', [0])[0]),
        'retry': int(args.get('retry', [0])[0]),
    }


def build_queue(queue_url, tests_index=None):
    spec = urlparse(queue_url)
    if spec.scheme == 'list':
        return ciqueue.Static(spec.path.split(':'))
    elif spec.scheme == 'file':
        return ciqueue.File(spec.path)
    elif spec.scheme == 'redis':
        redis_options = {'host': spec.hostname}
        if spec.port:
            redis_options['port'] = spec.port
        redis_client = redis.StrictRedis(**redis_options)

        kwargs = parse_redis_args(spec.query)
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
