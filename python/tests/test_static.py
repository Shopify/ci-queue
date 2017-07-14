from ciqueue import Static
from shared import QueueImplementation


class TestStatic(QueueImplementation):
    def build_queue(self):
        return Static(list(self.TEST_LIST), max_requeues=1,
                      requeue_tolerance=0.1)
