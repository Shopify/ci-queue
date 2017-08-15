import ciqueue
from tests import shared


class TestStatic(shared.QueueImplementation):

    def build_queue(self, **kwargs):
        return ciqueue.Static(list(self.TEST_LIST), max_requeues=1,
                              requeue_tolerance=0.1)
