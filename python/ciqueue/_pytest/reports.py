"""Transport rendered pytest reports, never exception or traceback objects."""
import json
import math
import zlib

import pytest
from _pytest.reports import TestReport


REPORT_FIELDS = {
    '$report_type', 'nodeid', 'location', 'keywords', 'outcome', 'longrepr', 'when',
    'sections', 'duration', 'start', 'stop', 'user_properties', 'wasxfail',
}


def dumps(config, reports):
    payload = {}
    for when, report in reports.items():
        data = config.hook.pytest_report_to_serializable(config=config, report=report)
        # Plugin-specific attributes are not part of the queue's report protocol.
        payload[when] = {key: value for key, value in data.items() if key in REPORT_FIELDS}
        # JUnit renders property values as text; arbitrary objects stay on the worker.
        payload[when]['user_properties'] = [(name, str(value)) for name, value in report.user_properties]
    return zlib.compress(json.dumps(payload, allow_nan=False).encode('utf-8'))


def _location(value, allow_none=False):
    return (isinstance(value, list) and len(value) == 3 and
            isinstance(value[0], str) and isinstance(value[2], str) and
            (type(value[1]) is int or (allow_none and value[1] is None)))


def _pairs(value):
    return isinstance(value, list) and all(
        isinstance(pair, list) and len(pair) == 2 and
        all(isinstance(part, str) for part in pair) for pair in value)


def _validate(data, when, nodeid):
    if not isinstance(data, dict) or not data.keys() <= REPORT_FIELDS:
        raise ValueError('unsupported report fields')
    if (data.get('$report_type') != 'TestReport' or data.get('nodeid') != nodeid or
            data.get('when') != when or data.get('outcome') not in ('failed', 'skipped')):
        raise ValueError('invalid report identity or outcome')
    if not _location(data.get('location'), allow_none=True) or not isinstance(data.get('keywords'), dict):
        raise ValueError('invalid report location or keywords')
    if not _pairs(data.get('sections', [])) or not _pairs(data.get('user_properties', [])):
        raise ValueError('invalid report sections or properties')
    for name in ('duration', 'start', 'stop'):
        if name in data and (type(data[name]) not in (int, float) or not math.isfinite(data[name])):
            raise ValueError('invalid report timing')
    if 'wasxfail' in data and (not isinstance(data['wasxfail'], str) or data['outcome'] != 'skipped'):
        raise ValueError('xfail metadata requires a skipped outcome')
    longrepr = data.get('longrepr')
    if isinstance(longrepr, list):
        if not _location(longrepr):
            raise ValueError('invalid skip representation')
        data['longrepr'] = tuple(longrepr)
    elif isinstance(longrepr, dict):
        if not {'reprcrash', 'reprtraceback', 'sections', 'chain'} <= longrepr.keys():
            raise ValueError('invalid traceback representation')
    elif not isinstance(longrepr, str):
        raise ValueError('missing failure representation')
    if data['outcome'] == 'skipped' and 'wasxfail' not in data and not isinstance(data['longrepr'], tuple):
        raise ValueError('missing skip location')
    data['location'] = tuple(data['location'])


def loads(config, payload, nodeid):
    try:
        data = json.loads(zlib.decompress(payload).decode('utf-8'))
        if not isinstance(data, dict) or not data or not data.keys() <= {'setup', 'call', 'teardown'}:
            raise ValueError('expected setup/call/teardown reports')
        if 'setup' in data and 'call' in data:
            raise ValueError('a non-passing setup cannot have a call report')
        reports = {}
        for when, report_data in data.items():
            _validate(report_data, when, nodeid)
            report = config.hook.pytest_report_from_serializable(config=config, data=report_data)
            if not isinstance(report, TestReport):
                raise ValueError('expected a TestReport')
            # Exercise pytest's structured traceback renderer before accepting a record.
            # Malformed nested representations must fail here, not during reporting.
            _ = report.longreprtext
            reports[when] = report
        return reports
    except (ValueError, TypeError, KeyError, AttributeError, AssertionError, RuntimeError, zlib.error) as error:
        raise pytest.UsageError(
            'Invalid error report for {}: {}. Expected compressed JSON reports; '
            'upgrade workers and reporter together and use a fresh build ID.'.format(nodeid, error)) from error
