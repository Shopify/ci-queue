import os
import subprocess
import redis


def test_integration():
    expected_result = '2 failed, 2 passed, 6 error'
    r = redis.StrictRedis(host=os.getenv('REDIS_HOST'))
    r.flushdb()

    # happy paths
    assert expected_result in subprocess.check_output(
        'py.test integrations/pytest; exit 0', shell=True, stderr=subprocess.STDOUT)
    output = subprocess.check_output(
        "py.test -p ciqueue.pytest --queue 'redis://localhost:6379/0?worker=0&build=foo&retry=0' integrations/pytest; exit 0",
        shell=True, stderr=subprocess.STDOUT)
    assert expected_result in output, output
    assert expected_result in subprocess.check_output(
        "py.test -p ciqueue.pytest_report --queue 'redis://localhost:6379/0?worker=0&build=foo&retry=0' integrations/pytest; exit 0",
        shell=True, stderr=subprocess.STDOUT)

    # test that report strickty reports what's on the redis queue
    r.delete('build:foo:error-reports')
    assert '8 passed' in subprocess.check_output(
        "py.test -p ciqueue.pytest_report --queue 'redis://localhost:6379/0?worker=0&build=foo&retry=0' integrations/pytest; exit 0",
        shell=True, stderr=subprocess.STDOUT)
