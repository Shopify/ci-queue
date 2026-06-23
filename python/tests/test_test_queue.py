import uritools
import ciqueue.distributed
from ciqueue._pytest import test_queue


class TestTestQueue:
    def test_initialise_from_redis_uri(self):
        queue = test_queue.build_queue('redis://localhost:6379/0?worker=1&build=12345', None)
        assert isinstance(queue, ciqueue.distributed.Supervisor)
        assert queue.redis is not None

    def test_initialise_from_rediss_uri(self):
        queue = test_queue.build_queue('rediss://localhost:6379/0?worker=1&build=12345', None)
        assert isinstance(queue, ciqueue.distributed.Supervisor)
        assert queue.redis is not None

    def test_parse_redis_args_with_username_and_password(self):
        spec = uritools.urisplit('redis://user:secret@localhost:6379/0')
        args = test_queue.parse_redis_args(spec)
        assert args['username'] == 'user'
        assert args['password'] == 'secret'
        assert args['host'] == 'localhost'

    def test_parse_redis_args_with_password_only(self):
        spec = uritools.urisplit('redis://:secret@localhost:6379/0')
        args = test_queue.parse_redis_args(spec)
        assert 'username' not in args
        assert args['password'] == 'secret'

    def test_parse_redis_args_without_credentials(self):
        spec = uritools.urisplit('redis://localhost:6379/0')
        args = test_queue.parse_redis_args(spec)
        assert 'username' not in args
        assert 'password' not in args
