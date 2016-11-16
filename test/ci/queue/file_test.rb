require 'test_helper'

class CI::Queue::FileTest < Minitest::Test
  include SharedQueueAssertions

  TEST_LIST_PATH = '/tmp/queue-test.txt'.freeze

  def setup
    File.write(TEST_LIST_PATH, TEST_LIST.join("\n"))
    @queue = CI::Queue::File.new(TEST_LIST_PATH, max_requeues: 1)
  end
end
