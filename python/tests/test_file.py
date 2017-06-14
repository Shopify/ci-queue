from ciqueue import File
from shared import QueueImplementation


class TestFile(QueueImplementation):
  TEST_LIST_PATH = '/tmp/queue-test.txt'
  def build_queue(self):
    with open(self.TEST_LIST_PATH, 'w+') as f:
      f.write("\n".join(self.TEST_LIST))
    return File(self.TEST_LIST_PATH, max_requeues=1, requeue_tolerance=0.1)
