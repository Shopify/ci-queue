require 'test_helper'

class CI::Queue::FileTest < Minitest::Test
  include SharedQueueAssertions

  TEST_LIST_PATH = '/tmp/queue-test.txt'.freeze

  private

  def build_queue
    File.write(TEST_LIST_PATH, TEST_LIST.map(&:name).join("\n"))
    CI::Queue::File.new(TEST_LIST_PATH, max_requeues: 1, requeue_tolerance: 0.1)
  end
end
