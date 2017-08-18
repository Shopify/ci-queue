class QueueImplementation(object):
    TEST_LIST = [
        'ATest#test_foo',
        'ATest#test_bar',
        'BTest#test_foo',
        'BTest#test_bar',
    ]

    def build_queue(self, **kwargs):
        raise NotImplementedError()

    def test_progress(self):
        queue = self.build_queue()
        expected_progress = 0
        for test in queue:
            assert queue.progress == expected_progress
            queue.acknowledge(test)
            expected_progress += 1
        assert queue.progress == expected_progress

    def test_len(self):
        queue = self.build_queue()
        assert len(queue) == len(self.TEST_LIST)

    def test_order(self):
        queue = self.build_queue()
        test_order = []
        for test in queue:
            test_order.append(test)
            queue.acknowledge(test)

        assert test_order == self.TEST_LIST

    def requeue(self):
        queue = self.build_queue()

        test_order = []
        for test in queue:
            queue.requeue(test)
            queue.acknowledge(test)
            test_order.append(test)
        return test_order

    def test_requeue(self):
        assert self.requeue() == [self.TEST_LIST[0]] + self.TEST_LIST

    def test_acknowledge(self):
        queue = self.build_queue()

        for test in queue:
            assert queue.acknowledge(test) is True

    @staticmethod
    def work_off(queue):
        test_order = []
        for test in queue:
            test_order.append(test)
            queue.acknowledge(test)
        return test_order
