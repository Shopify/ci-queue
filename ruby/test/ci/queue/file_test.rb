require 'test_helper'

class CI::Queue::FileTest < Minitest::Test
  include SharedQueueAssertions

  TEST_LIST_PATH = '/tmp/queue-test.txt'.freeze

  private

  def build_queue
    File.write(TEST_LIST_PATH, TEST_LIST.map(&:name).join("\n"))
    CI::Queue::File.new(TEST_LIST_PATH, max_requeues: 1, requeue_tolerance: 0.1)
  end

  def test_from_uri
    log_path = File.expand_path('../../fixtures/test_order.log', __dir__)
    queue = CI::Queue.from_uri("file://#{log_path}?max_requeues=42&requeue_tolerance=0.7")
    assert_instance_of CI::Queue::File, queue
    assert_equal %w(foo bar plop?fizz), queue.to_a
    assert_equal 42, queue.max_requeues
    assert_equal 3, queue.global_max_requeues
  end
end
