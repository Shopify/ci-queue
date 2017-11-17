require 'test_helper'

class CI::Queue::StaticTest < Minitest::Test
  include SharedQueueAssertions

  private

  def build_queue
    CI::Queue::Static.new(TEST_LIST.map(&:name), max_requeues: 1, requeue_tolerance: 0.1)
  end
end
