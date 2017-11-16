require 'test_helper'

class CI::Queue::StaticTest < Minitest::Test
  include SharedQueueAssertions

  private

  def build_queue
    CI::Queue::Static.new(TEST_LIST.map(&:name), max_requeues: 1, requeue_tolerance: 0.1)
  end

  def test_from_uri
    queue = CI::Queue.from_uri('list:foo:bar:plop%3Ffizz?max_requeues=42&requeue_tolerance=0.7')
    assert_instance_of CI::Queue::Static, queue
    assert_equal %w(foo bar plop?fizz), queue.to_a
    assert_equal 42, queue.max_requeues
    assert_equal 3, queue.global_max_requeues
  end
end
