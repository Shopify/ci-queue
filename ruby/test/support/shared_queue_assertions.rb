# frozen_string_literal: true
require 'support/shared_test_cases'

module SharedQueueAssertions
  include SharedTestCases
  include QueueHelper

  def setup
    @queue = populate(build_queue)
  end

  def test_progess
    count = 0

    assert_equal 0, @queue.progress
    poll(@queue) do
      assert_equal count, @queue.progress
      count += 1
    end

    assert_equal TEST_LIST.size, @queue.progress
  end

  def test_circuit_breaker
    12.times { @queue.report_failure! }
    assert config.circuit_breakers.any?(&:open?)

    poll(@queue) do
      assert false, "The queue shouldn't have poped a test"
    end
    assert_equal TEST_LIST.size, @queue.size
  end

  def test_size
    assert_equal TEST_LIST.size, @queue.size
    poll(@queue)
    assert_equal 0, @queue.size
  end

  def test_exhausted?
    queue = build_queue
    refute_predicate queue, :exhausted?
    populate(queue)
    refute_predicate queue, :exhausted?
    poll(queue)
    assert_predicate queue, :exhausted?
  end

  def test_to_a
    assert_equal shuffled_test_list, @queue.to_a
    poll(@queue)
    assert_equal [], @queue.to_a
  end

  def test_size_and_to_a
    poll(@queue) do
      assert_equal @queue.to_a.size, @queue.size
    end
  end

  def test_poll_order
    assert_equal shuffled_test_list, poll(@queue)
  end

  def test_requeue
    assert_equal [shuffled_test_list.first, *shuffled_test_list], poll(@queue, false)
    assert_equal @queue.total, @queue.progress
  end

  def test_acknowledge
    @queue.poll do |test|
      assert_equal true, @queue.acknowledge(test)
    end
  end

  private

  def shuffled_test_list
    TEST_LIST.dup
  end

  def config
    @config ||= CI::Queue::Configuration.new(
      timeout: 0.2,
      build_id: '42',
      worker_id: '1',
      max_requeues: 1,
      requeue_tolerance: 0.1,
      max_consecutive_failures: 10,
    )
  end

  def populate(queue, tests: TEST_LIST.dup)
    queue.populate(tests, random: Random.new(0))
  end
end
