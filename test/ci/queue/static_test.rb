require 'test_helper'

class CI::Queue::StaticTest < Minitest::Test
  include SharedQueueAssertions

  def setup
    @queue = CI::Queue::Static.new(TEST_LIST.dup, max_requeues: 1, requeue_tolerance: 0.1)
  end
end
