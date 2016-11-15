module SharedQueueAssertions
  TEST_LIST = %w(
    TestCaseA#test_foo
    TestCaseA#test_bar
    TestCaseB#test_foo
    TestCaseB#test_bar
  ).freeze

  def test_progess
    count = 0

    assert_equal 0, @queue.progress
    @queue.poll do
      assert_equal count, @queue.progress
      count += 1
    end

    assert_equal TEST_LIST.size, @queue.progress
  end

  def test_size
    assert_equal TEST_LIST.size, @queue.size
    @queue.poll { }
    assert_equal 0, @queue.size
  end

  def test_empty?
    refute_predicate @queue, :empty?
    @queue.poll { }
    assert_predicate @queue, :empty?
  end

  def test_to_a
    assert_equal TEST_LIST, @queue.to_a
    @queue.poll { }
    assert_equal [], @queue.to_a
  end

  def test_size_and_to_a
    @queue.poll do
      assert_equal @queue.to_a.size, @queue.size
    end
  end

  def test_poll_order
    assert_equal TEST_LIST, @queue.to_enum(:poll).to_a
  end
  
end