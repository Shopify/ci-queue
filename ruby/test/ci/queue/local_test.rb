# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'

class CI::Queue::LocalTest < Minitest::Test
  include SharedQueueAssertions

  def setup
    @tmpdir = Dir.mktmpdir('ci-queue-local-test')
    super
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_from_uri
    queue = CI::Queue.from_uri("local://#{@tmpdir}/from-uri", config)
    assert_instance_of CI::Queue::Local::Worker, queue
  end

  def test_distributed
    refute_predicate @queue, :distributed?
  end

  def test_multi_worker_coordination
    # Simulate two workers sharing the same queue directory
    dir = File.join(@tmpdir, 'multi-worker')

    config1 = CI::Queue::Configuration.new(
      timeout: 0.2, build_id: '42', worker_id: '1',
      max_requeues: 0, requeue_tolerance: 0,
      max_consecutive_failures: 10,
    )
    config2 = CI::Queue::Configuration.new(
      timeout: 0.2, build_id: '42', worker_id: '2',
      max_requeues: 0, requeue_tolerance: 0,
      max_consecutive_failures: 10,
    )

    q1 = CI::Queue::Local::Worker.new(dir, config1)
    q1.populate(TEST_LIST.dup, random: Random.new(0))

    q2 = CI::Queue::Local::Worker.new(dir, config2)

    tests_from_1 = []
    tests_from_2 = []

    test_id = ->(test) {
      test.respond_to?(:id) ? test.id : CI::Queue::QueueEntry.test_id(test)
    }
    entry_for = ->(test) {
      test.respond_to?(:queue_entry) ? test.queue_entry : test
    }

    # Worker 1 takes first test
    q1.poll do |test|
      tests_from_1 << test_id.call(test)
      q1.acknowledge(entry_for.call(test))
      break  # stop after one
    end

    # Worker 2 takes remaining tests
    q2.poll do |test|
      tests_from_2 << test_id.call(test)
      q2.acknowledge(entry_for.call(test))
    end

    # Worker 1 takes whatever's left
    q1.poll do |test|
      tests_from_1 << test_id.call(test)
      q1.acknowledge(entry_for.call(test))
    end

    all_tests = (tests_from_1 + tests_from_2).sort
    assert_equal TEST_LIST.map(&:id).sort, all_tests
    # Each test should only be run once
    assert_equal all_tests.uniq, all_tests
  end

  def test_stream_populate
    dir = File.join(@tmpdir, 'stream')
    queue = CI::Queue::Local::Worker.new(dir, config)

    entries = TEST_LIST.map { |t| t }
    queue.stream_populate(entries.each, random: Random.new(0))

    assert_equal TEST_LIST.size, queue.total
    assert queue.populated?
  end

  def test_expired
    dir = File.join(@tmpdir, 'expired')
    queue = CI::Queue::Local::Worker.new(dir, config)
    queue.populate(TEST_LIST.dup, random: Random.new(0))

    refute queue.expired? # no created_at => not expired

    queue.created_at = CI::Queue.time_now
    refute queue.expired?
  end

  def test_build_error_reports
    dir = File.join(@tmpdir, 'build-errors')
    queue = CI::Queue::Local::Worker.new(dir, config)
    queue.populate(TEST_LIST.dup, random: Random.new(0))

    queue.poll do |test|
      queue.build.record_error(test.queue_entry, "some error")
      queue.acknowledge(test.queue_entry)
      break
    end

    refute_empty queue.build.error_reports
    assert_equal 1, queue.build.failed_tests.size
  end

  private

  def build_queue
    CI::Queue::Local::Worker.new(File.join(@tmpdir, 'queue'), config)
  end
end
