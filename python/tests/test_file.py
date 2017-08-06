import ciqueue
from tests import shared


class TestFile(shared.QueueImplementation):
    TEST_LIST_PATH = '/tmp/queue-test.txt'

    def build_queue(self, **kwargs):
        with open(self.TEST_LIST_PATH, 'w+') as test_file:
            test_file.write("\n".join(self.TEST_LIST))
        return ciqueue.File(self.TEST_LIST_PATH, max_requeues=1, requeue_tolerance=0.1)
