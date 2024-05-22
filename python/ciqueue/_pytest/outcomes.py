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
try:
    from _pytest import outcomes
except ImportError:
    from _pytest import runner as outcomes
from _pytest._code import code
from tblib import pickling_support

pickling_support.install()


class Skipped(Exception):
    """placeholder for outcomes.Skipped which is not serializable"""


class Failed(Exception):
    """placeholder for outcomes.Failed which is not serializable"""


class UnserializableException(Exception):
    """placeholder for any Exceptions that cannnot be serialized"""


SERIALIZE_TYPES = {outcomes.Skipped: Skipped,
                   outcomes.Failed: Failed}
DESERIALIZE_TYPES = {Skipped: outcomes.Skipped,
                     Failed: outcomes.Failed}


try:
    from_exc_info = code.ExceptionInfo.from_exc_info
except AttributeError:
    # pytest < 7.4
    def from_exc_info(tup):
        return code.ExceptionInfo(tup)


def swap_in_serializable(excinfo):
    def pickles(excinfo):
        try:
            return dill.pickles(excinfo)
        except BaseException:
            return False

    if excinfo.type in SERIALIZE_TYPES:
        cls = SERIALIZE_TYPES[excinfo.type]
        tup = (cls, cls(*excinfo.value.args), excinfo.tb)
        excinfo = from_exc_info(tup)
    elif not pickles(excinfo):
        tup = (UnserializableException,
               UnserializableException(
                   "Actual Exception thrown on test node was %r" %
                   excinfo.value),
               excinfo.tb)
        excinfo = from_exc_info(tup)
    return excinfo


def swap_back_original(excinfo):
    if excinfo.type in DESERIALIZE_TYPES:
        tipe = DESERIALIZE_TYPES[excinfo.type]
        tup = (tipe, tipe(*excinfo.value.args), excinfo.tb)
        return from_exc_info(tup)
    return excinfo


def marked_xfail(item):
    return hasattr(item, '_evalxfail') and item._evalxfail.istrue()  # pylint: disable=protected-access


def failed(item):
    return hasattr(item, 'error_reports') and \
        not marked_xfail(item) and \
        not all(issubclass(i['excinfo'].type, Skipped) for i in item.error_reports.values())


def skipped_excinfo(item, msg):
    traceback = list(item.error_reports.values())[0]['excinfo'].tb
    tup = (outcomes.Skipped, outcomes.Skipped(msg), traceback)
    return from_exc_info(tup)
