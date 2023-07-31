# frozen_string_literal: true
require 'test_helper'

class CI::Queue::FileTest < Minitest::Test
  include SharedQueueAssertions

  TEST_LIST_PATH = '/tmp/queue-test.txt'.freeze

  def test_from_uri
    log_path = File.expand_path('../../fixtures/test_order.log', __dir__)
    queue = CI::Queue.from_uri("file://#{log_path}", config)
    populate(queue)
    assert_instance_of CI::Queue::File, queue
    assert_equal %w(ATest#test_foo ATest#test_bar BTest#test_foo BTest#test_bar), queue.to_a.map(&:id)
  end

  private

  def build_queue
    File.write(TEST_LIST_PATH, TEST_LIST.map(&:id).join("\n"))
    CI::Queue::File.new(TEST_LIST_PATH, config)
  end
end
