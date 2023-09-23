import os
import subprocess
import redis

# pylint: disable=no-self-use


def expected_messages(output):
    assert '= 4 failed, 2 passed, 1 skipped, 1 xpassed, 6 errors in' in output, output
    assert ('integrations/pytest/test_all.py:27: skipping test message' in output
            or 'integrations/pytest/test_all.py:28: skipping test message' in output), output


def check_output(cmd):
    return subprocess.check_output(cmd, shell=True, stderr=subprocess.STDOUT).decode()


def get_tls_test_directory():
    return os.path.abspath(
        os.path.join(
            os.path.dirname(
                os.path.abspath(__file__)
            ),
            "..",
            "..",
            "tests",
            "tls"
        )
    )


class TestIntegration(object):
    def setup_method(self):
        self.redis_url = os.getenv('REDIS_URL', default='redis://localhost:6379/0')

        if self.redis_url.startswith("rediss://"):
            self.redis = redis.StrictRedis.from_url(
                self.redis_url,
                ssl_ca_certs=f"{get_tls_test_directory()}/ca.crt",
                ssl_certfile=f"{get_tls_test_directory()}/client.crt",
                ssl_keyfile=f"{get_tls_test_directory()}/client.key",
                ssl_cert_reqs="required"
            )
        else:
            self.redis = redis.StrictRedis.from_url(
                self.redis_url
            )

        self.redis.flushdb()

    def test_integration(self):
        # happy paths
        expected_messages(check_output('py.test -v -r a integrations/pytest/test_all.py; exit 0'))

        queue = f"{self.redis_url}?worker=0&build=foo&retry=0&timeout=5"
        filename = 'test_all.py'
        cmd = f"py.test -v -r a -p ciqueue.pytest --queue '{queue}' {self.amend_command_for_ssl()} integrations/pytest/{filename}; exit 0"
        report_cmd = f"py.test -v -r a -p ciqueue.pytest_report --queue '{queue}' {self.amend_command_for_ssl()} integrations/pytest/{filename}; exit 0"

        expected_messages(check_output(cmd))
        expected_messages(check_output(report_cmd))

        # test that pytest_report only reports what's on the redis queue
        self.redis.delete('build:foo:error-reports')
        queue = f"{self.redis_url}?build=foo&retry=0"
        output = check_output(report_cmd)
        assert '= 11 passed, 1 xpassed in' in output, output
        assert ('integrations/pytest/test_all.py:27: message' not in output
                and 'integrations/pytest/test_all.py:28: message' not in output), output

    def test_retries_and_junit_xml(self, tmpdir):
        queue = f"{self.redis_url}?worker=0&build=bar&retry=0&timeout=5&max_requeues=1&requeue_tolerance=0.2&socket_timeout=5&socket_connect_timeout=5&retry_on_timeout=true"
        filename = 'test_all.py'

        xml_file = os.path.join(tmpdir.strpath, 'test.xml')
        cmd = f"py.test -v -r a -p ciqueue.pytest --queue '{queue}' {self.amend_command_for_ssl()} --junit-xml='{xml_file}' integrations/pytest/{filename}; exit 0"
        report_cmd = (f"py.test -v -r a -p ciqueue.pytest_report --queue '{queue}' {self.amend_command_for_ssl()} "
                      f"--junit-xml='{xml_file}' integrations/pytest/{filename}; exit 0")

        output = check_output(cmd.format(queue, filename))
        assert '= 4 failed, 2 passed, 4 skipped, 1 xpassed, 6 errors in' in output, output
        assert ('integrations/pytest/test_all.py:27: skipping test message' in output
                or 'integrations/pytest/test_all.py:28: skipping test message' in output), output
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
        queue = f"{self.redis_url}?worker=0&build=bar&timeout=5&max_requeues=1&requeue_tolerance=0.2"
        filename = 'test_flakey.py'
        cmd = f"py.test -v -r a -p ciqueue.pytest --queue '{queue}' {self.amend_command_for_ssl()} integrations/pytest/{filename}"
        report_cmd = f"py.test -v -r a -p ciqueue.pytest_report --queue '{queue}' {self.amend_command_for_ssl()} integrations/pytest/{filename}"

        output = check_output(cmd)
        assert '= 1 passed, 1 skipped in' in output, output

        output = check_output(report_cmd)
        assert '= 1 passed in' in output, output

    def amend_command_for_ssl(self):
        if self.redis_url.startswith("rediss://"):
            test_directory = get_tls_test_directory()

            return (f"--redis-ca-file-path '{test_directory}/ca.crt' "
                    f"--redis-client-certificate-path '{test_directory}/client.crt' "
                    f"--redis-client-certificate-key-path '{test_directory}/client.key'")
        else:
            return ""
