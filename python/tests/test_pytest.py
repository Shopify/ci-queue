import json
import os
import pickle
import re
import subprocess
import sys
import textwrap
import xml.etree.ElementTree as ET
import zlib
import redis
import pytest

# pylint: disable=no-self-use


@pytest.fixture(autouse=True)
def change_test_dir(request, monkeypatch):
    monkeypatch.chdir(request.fspath.dirname + "/..")


def expected_messages(output):
    assert re.search(r'= 4 failed, 2 passed, 1 skipped, 1 xpassed, (1 warning, )?6 errors in', output), output
    assert re.search(r':\d+: skipping test message', output) is not None, \
        "did not find 'skipping test message' in output"


def check_output(cmd):
    return subprocess.check_output(cmd, shell=True, stderr=subprocess.STDOUT).decode()


class TestIntegration(object):
    def setup_method(self):
        strict_redis = redis.StrictRedis(host=os.getenv('REDIS_HOST'))
        strict_redis.flushdb()
        self.redis = strict_redis  # pylint: disable=attribute-defined-outside-init

    def test_integration(self):
        # happy paths
        expected_messages(check_output('py.test -v -r a integrations/pytest/test_all.py; exit 0'))

        queue = "redis://localhost:6379/0?worker=0&build=foo&retry=0&timeout=5"
        filename = 'test_all.py'
        cmd = "py.test -v -r a -p ciqueue.pytest --queue '{}' integrations/pytest/{}; exit 0"\
            .format(queue, filename)
        report_cmd = "py.test -v -r a -p ciqueue.pytest_report --queue '{}' integrations/pytest/{}; exit 0"\
            .format(queue, filename)

        expected_messages(check_output(cmd))
        expected_messages(check_output(report_cmd))

        # test that pytest_report only reports what's on the redis queue
        self.redis.delete('build:foo:error-reports')
        queue = "redis://localhost:6379/0?build=foo&retry=0"
        output = check_output(report_cmd)
        assert '= 11 passed, 1 xpassed in' in output, output

    def test_retries_and_junit_xml(self, tmpdir):
        queue = ('redis://localhost:6379/0?worker=0&build=bar&retry=0&timeout=5'
                 '&max_requeues=1&requeue_tolerance=0.2'
                 '&socket_timeout=5&socket_connect_timeout=5&retry_on_timeout=true')
        filename = 'test_all.py'

        xml_file = os.path.join(tmpdir.strpath, 'test.xml')
        cmd = "py.test -v -r a -p ciqueue.pytest --queue '{}' --junit-xml='{}' integrations/pytest/{}; exit 0"\
              .format(queue, xml_file, filename)
        report_cmd = ("py.test -v -r a -p ciqueue.pytest_report --queue '{}' "
                      "--junit-xml='{}' integrations/pytest/{}; exit 0")\
            .format(queue, xml_file, filename)

        output = check_output(cmd.format(queue, filename))
        assert re.search(r'= 4 failed, 2 passed, 4 skipped, 1 xpassed, (1 warning, )?6 errors in', output), output
        assert re.search(r':\d+: skipping test message', output), output
        assert ' WILL_RETRY ' in output, output

        xml = open(xml_file).read()
        assert xml.count('/failure') == 5
        assert xml.count('/skipped') == 4
        assert xml.count('/error') == 7

        expected_messages(check_output(report_cmd.format(queue, filename)))
        xml = open(xml_file).read()
        assert xml.count('/failure') == 4
        assert xml.count('/skipped') == 1
        assert xml.count('/error') == 6

    def test_flakey(self):
        queue = "redis://localhost:6379/0?worker=0&build=bar&timeout=5&max_requeues=1&requeue_tolerance=0.2"
        filename = 'test_flakey.py'
        cmd = "py.test -v -r a -p ciqueue.pytest --queue '{}' integrations/pytest/{}".format(queue, filename)
        report_cmd = "py.test -v -r a -p ciqueue.pytest_report --queue '{}' integrations/pytest/{}"\
                     .format(queue, filename)

        output = check_output(cmd)
        assert '= 1 passed, 1 skipped in' in output, output

        output = check_output(report_cmd)
        assert '= 1 passed in' in output, output

    def test_report_rejects_executable_records(self, tmp_path):
        sentinel = tmp_path / 'deserialized'

        class ExecutableRecord:
            def __reduce__(self):
                return os.mkdir, (str(sentinel),)

        nodeid = 'integrations/pytest/test_all.py::TestHappy::test_method'
        self.redis.set('build:unsafe:master-status', 'finished')
        self.redis.hset('build:unsafe:error-reports', nodeid,
                        zlib.compress(pickle.dumps(ExecutableRecord())))
        result = subprocess.run(
            [sys.executable, '-m', 'pytest', '-p', 'ciqueue.pytest_report',
             '--queue', 'redis://localhost:6379/0?build=unsafe', nodeid],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)

        assert not sentinel.exists(), result.stdout
        assert result.returncode != 0, result.stdout
        assert 'Invalid error report' in result.stdout
        assert nodeid in result.stdout

    @pytest.mark.parametrize('payload', [
        b'not compressed',
        zlib.compress(b'{'),
        zlib.compress(b'{}'),
        zlib.compress(b'{"collect": {}}'),
        zlib.compress(b'{"call": {"$report_type": "CollectReport"}}'),
    ])
    def test_report_rejects_invalid_records(self, payload):
        nodeid = 'integrations/pytest/test_all.py::TestHappy::test_method'
        self.redis.set('build:invalid:master-status', 'finished')
        self.redis.hset('build:invalid:error-reports', nodeid, payload)
        result = subprocess.run(
            [sys.executable, '-m', 'pytest', '-p', 'ciqueue.pytest_report',
             '--queue', 'redis://localhost:6379/0?build=invalid', nodeid],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)

        assert result.returncode == pytest.ExitCode.USAGE_ERROR, result.stdout
        assert nodeid in result.stdout

    def test_xfail_outcomes_survive_retries_and_reporting(self, tmp_path):
        test_file = tmp_path / 'test_outcomes.py'
        test_file.write_text(textwrap.dedent('''\
            import pytest

            @pytest.mark.xfail(reason="expected", raises=ValueError)
            def test_expected():
                raise ValueError("expected")

            @pytest.mark.xfail(reason="wrong exception", raises=TypeError)
            def test_unexpected():
                raise ValueError("not a TypeError")

            @pytest.mark.xfail(strict=True, reason="must fail")
            def test_strict():
                pass

            def test_dynamic():
                pytest.xfail("dynamic reason")

            @pytest.fixture
            def cleanup():
                yield
                pytest.xfail("cleanup")

            def test_cleanup(cleanup):
                assert False, "call failed before cleanup"
        '''))
        queue = ('redis://localhost:6379/0?worker=0&build=xfail&timeout=5'
                 '&max_requeues=1&requeue_tolerance=1')
        worker = subprocess.run(
            [sys.executable, '-m', 'pytest', '-ra', '-p', 'ciqueue.pytest',
             '--queue', queue, str(test_file)],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)
        assert worker.returncode == pytest.ExitCode.TESTS_FAILED, worker.stdout
        assert '3 failed, 3 skipped, 3 xfailed' in worker.stdout

        xml_file = tmp_path / 'report.xml'
        reporter = subprocess.run(
            [sys.executable, '-m', 'pytest', '-ra', '-p', 'ciqueue.pytest_report',
             '--queue', queue, '--junitxml', str(xml_file), str(test_file)],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)
        assert reporter.returncode == pytest.ExitCode.TESTS_FAILED, reporter.stdout
        assert '3 failed, 3 xfailed' in reporter.stdout
        cases = {case.get('name'): case for case in ET.parse(xml_file).iter('testcase')}
        assert cases['test_expected'].find('skipped').get('message') == 'expected'
        assert cases['test_dynamic'].find('skipped').get('message') == 'dynamic reason'
        assert 'not a TypeError' in cases['test_unexpected'].find('failure').text
        assert '[XPASS(strict)]' in cases['test_strict'].find('failure').text

    @pytest.mark.parametrize('corruption', ['identity', 'xfail', 'phases'])
    def test_report_rejects_inconsistent_records(self, corruption):
        nodeid = 'integrations/pytest/test_all.py::TestSadTest::test_method'
        queue = 'redis://localhost:6379/0?worker=0&build=identity&timeout=5'
        worker = subprocess.run(
            [sys.executable, '-m', 'pytest', '-p', 'ciqueue.pytest', '--queue', queue, nodeid],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)
        assert worker.returncode == pytest.ExitCode.TESTS_FAILED, worker.stdout
        key = 'build:identity:error-reports'
        data = json.loads(zlib.decompress(self.redis.hget(key, nodeid)))
        if corruption == 'identity':
            data['call']['nodeid'] = 'another-test'
        elif corruption == 'xfail':
            data['call']['wasxfail'] = ''
        else:
            data['setup'] = dict(data['call'], when='setup', outcome='skipped',
                                 longrepr=['test_all.py', 1, 'Skipped: contradictory setup'])
        self.redis.hset(key, nodeid, zlib.compress(json.dumps(data).encode('utf-8')))
        reporter = subprocess.run(
            [sys.executable, '-m', 'pytest', '-p', 'ciqueue.pytest_report', '--queue', queue, nodeid],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)

        assert reporter.returncode == pytest.ExitCode.USAGE_ERROR, reporter.stdout
        assert nodeid in reporter.stdout

    def test_report_preserves_rendered_user_properties(self, tmp_path):
        test_file = tmp_path / 'test_properties.py'
        test_file.write_text(textwrap.dedent('''\
            from pathlib import Path

            def test_failure(record_property):
                record_property("artifact", Path("output.txt"))
                assert False, "original failure"
        '''))
        queue = 'redis://localhost:6379/0?worker=0&build=properties&timeout=5'
        for plugin in ('ciqueue.pytest', 'ciqueue.pytest_report'):
            xml_file = tmp_path / (plugin + '.xml')
            result = subprocess.run(
                [sys.executable, '-m', 'pytest', '-p', plugin, '--queue', queue,
                 '--junitxml', str(xml_file), '-o', 'junit_family=xunit1', str(test_file)],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)

            assert result.returncode == pytest.ExitCode.TESTS_FAILED, result.stdout
            case = next(ET.parse(xml_file).iter('testcase'))
            assert 'original failure' in case.find('failure').text
            assert case.find('properties/property').attrib == {'name': 'artifact', 'value': 'output.txt'}
