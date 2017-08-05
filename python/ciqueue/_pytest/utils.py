from __future__ import absolute_import
import ciqueue
import ciqueue.distributed
import redis
from _pytest import runner
from _pytest._code import code
from urlparse import parse_qs
from uritools import urisplit
from tblib import pickling_support
pickling_support.install()
import dill


class InvalidRedisUrl(Exception):
    pass


class Skipped(Exception):
    "placeholder for runner.Skipped which is not serializable"


class Failed(Exception):
    "placeholder for runner.Failed which is not serializable"


class UnserializableException(Exception):
    "placeholder for any Exceptions that cannnot be serialized"


SER = {runner.Skipped: Skipped,
       runner.Failed: Failed}
DESER = {Skipped: runner.Skipped,
         Failed: runner.Failed}


def swap_in_serializable(excinfo):
    if excinfo.type in SER:
        cls = SER[excinfo.type]
        tup = (cls, cls(*excinfo.value.args), excinfo.tb)
        excinfo = code.ExceptionInfo(tup)
    elif not dill.pickles(excinfo):
        tup = (UnserializableException,
               UnserializableException(
                   "Actual Exception thrown on test node was %r" %
                   excinfo.value),
               excinfo.tb)
        excinfo = code.ExceptionInfo(tup)
    return excinfo


def swap_back_original(excinfo):
    if excinfo.type in DESER:
        tipe = DESER[excinfo.type]
        tup = (tipe, tipe(*excinfo.value.args), excinfo.tb)
        return code.ExceptionInfo(tup)
    return excinfo


def key_item(item):
    # TODO: discuss better identifier
    return item.location[0] + '@' + item.location[2]


def parse_redis_args(query_string):
    args = parse_qs(query_string)

    if 'worker' not in args or not args['worker']:
        raise InvalidRedisUrl("Missing `worker` parameter in {}"
                              .format(query_string))

    if 'build' not in args or not args['build']:
        raise InvalidRedisUrl("Missing `build` parameter in {}"
                              .format(query_string))

    return {
        'worker_id': args['worker'][0],
        'build_id': args['build'][0],
        'timeout': float(args.get('timeout', [0])[0]),
        'max_requeues': int(args.get('max_requeues', [0])[0]),
        'requeue_tolerance': float(args.get('requeue_tolerance', [0])[0]),
        'retry': int(args.get('retry', [0])[0]),
    }


def build_queue(queue_url, tests_index=None):
    spec = urisplit(queue_url)
    if spec.scheme == 'list':
        return ciqueue.Static(spec.path.split(':'))
    elif spec.scheme == 'file':
        return ciqueue.File(spec.path)
    elif spec.scheme == 'redis':

        redis_options = {'host': spec.authority.split(':')[0],
                         'db': int(spec.path[1:] or 0)}
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
