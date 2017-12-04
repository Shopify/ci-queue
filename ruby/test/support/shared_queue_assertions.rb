module SharedQueueAssertions
  class TestCase
    attr_reader :name

    def initialize(name)
      @name = name
    end

    def inspect
      "#<TestCase #{name}>"
    end

    def id
      name
    end

    def to_s
      inspect
    end

    def <=>(other)
      self.name <=> other
    end
  end

  include QueueHelper

  TEST_LIST = %w(
    ATest#test_foo
    ATest#test_bar
    BTest#test_foo
    BTest#test_bar
  ).map { |n| TestCase.new(n).freeze }.freeze

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
    )
  end

  def populate(queue, tests: TEST_LIST.dup)
    queue.populate(tests, random: Random.new(0))
  end
end
