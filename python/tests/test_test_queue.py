import ciqueue.distributed
from ciqueue._pytest import test_queue


class TestTestQueue:
    def test_initialise_from_redis_uri(self):
        queue = test_queue.build_queue('redis://localhost:6379/0?worker=1&build=12345', None)
        assert type(queue) is ciqueue.distributed.Supervisor
        assert queue.redis is not None

    def test_initialise_from_rediss_uri(self):
        queue = test_queue.build_queue('rediss://localhost:6379/0?worker=1&build=12345', None)
        assert type(queue) is ciqueue.distributed.Supervisor
        assert queue.redis is not None
