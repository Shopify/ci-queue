from __future__ import absolute_import
import dill
from _pytest import runner
from _pytest._code import code
from tblib import pickling_support

pickling_support.install()


class Skipped(Exception):
    "placeholder for runner.Skipped which is not serializable"


class Failed(Exception):
    "placeholder for runner.Failed which is not serializable"


class UnserializableException(Exception):
    "placeholder for any Exceptions that cannnot be serialized"


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
