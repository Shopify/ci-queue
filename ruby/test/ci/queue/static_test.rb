# frozen_string_literal: true
require 'test_helper'

class CI::Queue::StaticTest < Minitest::Test
  include SharedQueueAssertions

  def test_expired
    queue = CI::Queue.from_uri('list:foo:bar:plop%3Ffizz', config)
    assert queue.expired?

    queue.created_at = Time.now
    refute queue.expired?
  end

  def test_populate_lazy_raises_not_implemented
    queue = build_queue

    error = assert_raises(NotImplementedError) do
      queue.populate_lazy(test_files: [], random: Random.new, config: config)
    end

    assert_match(/not supported for static queues/, error.message)
    assert_match(/Redis queue/, error.message)
  end

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
