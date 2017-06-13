module SharedQueueAssertions
  include QueueHelper

  TEST_LIST = %w(
    ATest#test_foo
    ATest#test_bar
    BTest#test_foo
    BTest#test_bar
  ).freeze

  def test_progess
    count = 0

    assert_equal 0, @queue.progress
    poll(@queue) do
      assert_equal count, @queue.progress
      count += 1
    end

    assert_equal TEST_LIST.size, @queue.progress
  end

  def test_size
    assert_equal TEST_LIST.size, @queue.size
    poll(@queue)
    assert_equal 0, @queue.size
  end

  def test_empty?
    refute_predicate @queue, :empty?
    poll(@queue)
    assert_predicate @queue, :empty?
  end

  def test_to_a
    assert_equal TEST_LIST, @queue.to_a
    poll(@queue)
    assert_equal [], @queue.to_a
  end

  def test_size_and_to_a
    poll(@queue) do
      assert_equal @queue.to_a.size, @queue.size
    end
  end

  def test_poll_order
    assert_equal TEST_LIST, poll(@queue)
  end

  def test_requeue
    assert_equal [TEST_LIST.first, *TEST_LIST], poll(@queue, false)
  end

  def test_acknowledge
    @queue.poll do |test|
      assert_equal true, @queue.acknowledge(test)
    end
  end
end
