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

  def test_poll_skips_missing_test
    queue = CI::Queue::Static.new((TEST_LIST + [TestCase.new('ATest#i_do_not_exist')]).map(&:id), config)
    populate(queue)

    expected_output = <<~OUTPUT
      Test not found: ATest#i_do_not_exist
    OUTPUT

    out, _ = capture_io do
      assert_equal shuffled_test_list, poll(queue)
    end

    assert_equal expected_output, out
  end

  def test_to_a_skips_missing_test
    queue = CI::Queue::Static.new((TEST_LIST + [TestCase.new('ATest#i_do_not_exist')]).map(&:id), config)
    populate(queue)

    expected_output = <<~OUTPUT
      Test not found: ATest#i_do_not_exist
    OUTPUT

    out, _ = capture_io do
      assert_equal shuffled_test_list, queue.to_a
    end

    assert_equal expected_output, out
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
