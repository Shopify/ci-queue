import os
import redis
from ciqueue import distributed
from shared import QueueImplementation


class TestDistributed(QueueImplementation):

    def setup_method(self, test_method):
        self._redis = redis.StrictRedis(
            host=os.getenv('REDIS_HOST')
        )
        self._redis.flushdb()

    def build_queue(self, id=1):
        return distributed.Worker(
            self.TEST_LIST,
            redis=self._redis,
            worker_id=str(id),
            build_id=42,
            timeout=0.2,
            max_requeues=1,
            requeue_tolerance=0.1,
        )

    def test_requeue(self):
        queue = self.build_queue()

        test_order = []
        for test in queue:
            test_order.append(test)
            queue.requeue(test)
        assert test_order == self.TEST_LIST + [self.TEST_LIST[0]]

    def test_retry_queue(self):
        queue = self.build_queue()
        assert len(queue) == len(self.TEST_LIST)
        initial_test_order = self.work_off(queue)
        retry_queue = queue.retry_queue()
        assert len(retry_queue) == len(self.TEST_LIST)
        retry_test_order = self.work_off(retry_queue)
        assert retry_test_order == initial_test_order

    def test_shutdown(self):
        queue = self.build_queue()
        count = 0

        for test in queue:
            count += 1
            queue.shutdown()

        assert count == 1

    def test_master_election(self):
        first_queue = self.build_queue(1)
        assert first_queue.is_master

        second_queue = self.build_queue(1)
        assert not second_queue.is_master
