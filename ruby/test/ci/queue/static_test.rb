# frozen_string_literal: true
require 'test_helper'

class CI::Queue::StaticTest < Minitest::Test
  include SharedQueueAssertions

  private

  def build_queue
    CI::Queue::Static.new(TEST_LIST.map(&:id), config)
  end

  def test_from_uri
    queue = CI::Queue.from_uri('list:foo:bar:plop%3Ffizz', config)
    assert_instance_of CI::Queue::Static, queue
    assert_equal %w(foo bar plop?fizz), queue.to_a
  end
end
