"""
This module is used for querying and altering test outcomes, and loosely
follows pytest's _pytest.outcomes.py in version 3.2 onwards.

Much of his module exists because pytest adds the field `__module__ = 'builtins'`
to the Skipped and Failed exception classes, rendering them unserializable.
We get around this by creating our own serializable version of
these classes, which we swap in in place of the original when we want to
be put them on the redis queue. Then, we swap back in the original exception
when reading off the queue. These operations are performed by
`swap_in_serializable` and `swap_back_original`, respectively.
"""


from __future__ import absolute_import
import dill
from _pytest import runner
from _pytest._code import code
from tblib import pickling_support

pickling_support.install()


class Skipped(Exception):
    """placeholder for runner.Skipped which is not serializable"""


class Failed(Exception):
    """placeholder for runner.Failed which is not serializable"""


class UnserializableException(Exception):
    """placeholder for any Exceptions that cannnot be serialized"""


SERIALIZE_TYPES = {runner.Skipped: Skipped,
                   runner.Failed: Failed}
DESERIALIZE_TYPES = {Skipped: runner.Skipped,
                     Failed: runner.Failed}


def swap_in_serializable(excinfo):
    if excinfo.type in SERIALIZE_TYPES:
        cls = SERIALIZE_TYPES[excinfo.type]
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
    if excinfo.type in DESERIALIZE_TYPES:
        tipe = DESERIALIZE_TYPES[excinfo.type]
        tup = (tipe, tipe(*excinfo.value.args), excinfo.tb)
        return code.ExceptionInfo(tup)
    return excinfo


def marked_xfail(item):
    return hasattr(item, '_evalxfail') and item._evalxfail.istrue()  # pylint: disable=protected-access


def failed(item):
    return hasattr(item, 'error_reports') and \
        not marked_xfail(item) and \
        not all(issubclass(i['excinfo'].type, Skipped) for i in item.error_reports.values())


def mark_as_skipped(call, item, stats, msg):
    assert call.when == 'teardown'

    def clear_out_stats(key):
        if key in stats:
            stats[key] = [i for i in stats[key] if i.nodeid != item.nodeid]
            if not stats[key]:
                del stats[key]

    # the call is converted to a skip
    traceback = item.error_reports.values()[0]['excinfo'].tb
    tup = (runner.Skipped, runner.Skipped(msg), traceback)
    call.excinfo = code.ExceptionInfo(tup)

    # clear out the stats like the test never happened
    for key in ('passed', 'error', 'failed'):
        clear_out_stats(key)

    # rollback the testsfailed number like it never happened
    item.session.testsfailed -= len([v for k, v in item.error_reports.iteritems()
                                     if not issubclass(v['excinfo'].type, Skipped) and k != 'teardown'])

    # and clear out any state on the item like it never happened
    if hasattr(item, 'error_reports'):
        del item.error_reports
