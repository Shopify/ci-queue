import os
import subprocess
import redis


def test_integration():
    def expected_messages(output):
        assert '4 failed, 2 passed, 1 skipped, 1 xpassed, 6 error' in output, output
        assert 'skipping test message' in output, output

    strict_redis = redis.StrictRedis(host=os.getenv('REDIS_HOST'))
    strict_redis.flushdb()

    # happy paths
    expected_messages(subprocess.check_output(
        'py.test -v -r a integrations/pytest; exit 0',
        shell=True, stderr=subprocess.STDOUT))

    queue = "'redis://localhost:6379/0?worker=0&build=foo&retry=0'"

    expected_messages(subprocess.check_output(
        "py.test -v -r a -p ciqueue.pytest --queue {} integrations/pytest; exit 0".format(queue),
        shell=True, stderr=subprocess.STDOUT))

    expected_messages(subprocess.check_output(
        "py.test -v -r a -p ciqueue.pytest_report --queue {} integrations/pytest; exit 0".format(queue),
        shell=True, stderr=subprocess.STDOUT))

    # test that pytest_report only reports what's on the redis queue
    strict_redis.delete('build:foo:error-reports')
    output = subprocess.check_output(
        "py.test -v -r a -p ciqueue.pytest_report --queue {} integrations/pytest; exit 0".format(queue),
        shell=True, stderr=subprocess.STDOUT)
    assert '11 passed, 1 xpassed' in output, output
    assert 'integrations/pytest/test_all.py:27: message' not in output, output
