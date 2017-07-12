import os
import subprocess
import redis


def test_integration():
    expected_result = '4 failed, 2 passed, 1 skipped, 1 xpassed, 6 error'
    r = redis.StrictRedis(host=os.getenv('REDIS_HOST'))
    r.flushdb()

    # happy paths
    output = subprocess.check_output(
        'py.test -v integrations/pytest; exit 0',
        shell=True, stderr=subprocess.STDOUT)
    assert expected_result in output, output

    output = subprocess.check_output(
        "py.test -v -p ciqueue.pytest --queue 'redis://localhost:6379/0?worker=0&build=foo&retry=0' integrations/pytest; exit 0",
        shell=True, stderr=subprocess.STDOUT)
    assert expected_result in output, output

    output = subprocess.check_output(
        "py.test -v -p ciqueue.pytest_report --queue 'redis://localhost:6379/0?worker=0&build=foo&retry=0' integrations/pytest; exit 0",
        shell=True, stderr=subprocess.STDOUT)
    assert expected_result in output, output

    # test that pytest_report only reports what's on the redis queue
    r.delete('build:foo:error-reports')
    output = subprocess.check_output(
        "py.test -v -p ciqueue.pytest_report --queue 'redis://localhost:6379/0?worker=0&build=foo&retry=0' integrations/pytest; exit 0",
        shell=True, stderr=subprocess.STDOUT)
    assert '11 passed, 1 xpassed' in output, output
