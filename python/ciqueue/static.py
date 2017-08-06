import math


class Static(object):
    distributed = False

    def __init__(self, tests, max_requeues=0, requeue_tolerance=0):
        self.queue = tests
        self.progress = 0
        self.total = len(tests)
        self.max_requeues = max_requeues
        self.global_max_requeues = math.ceil(requeue_tolerance * self.total)
        self.requeues = {}

    def __len__(self):
        return len(self.queue)

    def __iter__(self):
        while self.queue:
            yield self.queue.pop(0)
            self.progress += 1

    def acknowledge(self, test):  # pylint: disable=no-self-use,unused-argument
        return True

    def requeue(self, test):
        if self.requeues.get(test, 0) >= self.max_requeues:
            return False
        if sum(self.requeues.values()) >= self.global_max_requeues:
            return False

        self.requeues[test] = self.requeues.get(test, 0) + 1
        self.queue.insert(0, test)
        return True
