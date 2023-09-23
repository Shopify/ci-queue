from distutils import util  # pylint: disable=no-name-in-module, import-modules-only
from future.moves.urllib import parse as urlparse
import ciqueue
import ciqueue.distributed
import redis
import uritools


class InvalidRedisUrl(Exception):
    pass


def key_item(item):
    return item.nodeid


def parse_worker_args(query_string, tests_index):
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


def parse_redis_args(spec, config):
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
        result['retry_on_timeout'] = bool(util.strtobool(query['retry_on_timeout'][0] or 'false'))

    if config.getoption('--queue').startswith("rediss://"):
        result['ssl'] = True

    redis_ca_file_path = config.getoption('--redis-ca-file-path', default=None)
    if redis_ca_file_path is not None:
        result['ssl_ca_certs'] = redis_ca_file_path

    redis_client_certificate_path = config.getoption('--redis-client-certificate-path', default=None)
    if redis_client_certificate_path is not None:
        result['ssl_certfile'] = redis_client_certificate_path

    redis_client_certificate_key_path = config.getoption('--redis-client-certificate-key-path', default=None)
    if redis_client_certificate_key_path is not None:
        result['ssl_keyfile'] = redis_client_certificate_key_path

    if redis_client_certificate_path is not None or redis_client_certificate_key_path is not None:
        result['ssl_cert_reqs'] = "required"
    else:
        result['ssl_cert_reqs'] = "none"

    return result


def build_queue(config, tests_index=None):
    spec = uritools.urisplit(config.getoption('--queue'))
    if spec.scheme == 'list':
        return ciqueue.Static(spec.path.split(':'))
    elif spec.scheme == 'file':
        return ciqueue.File(spec.path)
    elif spec.scheme == 'redis' or spec.scheme == 'rediss':
        redis_args = parse_redis_args(spec, config)
        redis_client = redis.StrictRedis(**redis_args)

        worker_args = parse_worker_args(spec.query, tests_index)
        retry = bool(worker_args['retry'])
        del worker_args['retry']

        klass = ciqueue.distributed.Worker
        if tests_index is None:
            klass = ciqueue.distributed.Supervisor
        queue = klass(tests=tests_index, redis=redis_client, **worker_args)
        if retry and tests_index:
            queue = queue.retry_queue()
        return queue
    else:
        raise "Unknown queue scheme: " + repr(spec.scheme)
