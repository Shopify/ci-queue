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

  def test_from_uri
    queue = CI::Queue.from_uri('list:foo:bar:plop%3Ffizz', config)
    assert_instance_of CI::Queue::Static, queue
    assert_equal %w(foo bar plop?fizz), queue.to_a
  end

  def test_retry_stream_populate_is_noop
    failed_entries = ["ATest#test_foo\t/tmp/a_test.rb", "BTest#test_bar\t/tmp/b_test.rb"]
    retry_queue = CI::Queue::Redis::Retry.new(
      failed_entries,
      config,
      redis: nil, # not needed for this unit test
    )

    # stream_populate should preserve the existing queue
    replacement = Enumerator.new do |y|
      y << "ZTest#test_zzz\t/tmp/z_test.rb"
    end
    retry_queue.stream_populate(replacement, random: Random.new(0))

    assert_equal failed_entries, retry_queue.instance_variable_get(:@queue)
    assert_equal failed_entries.size, retry_queue.total
  end

  def test_retry_queue_poll_with_entry_resolver
    entry = "ATest#test_foo\t/tmp/a_test.rb"
    retry_queue = CI::Queue::Redis::Retry.new(
      [entry],
      config,
      redis: nil,
    )

    resolved = []
    retry_queue.entry_resolver = ->(e) {
      resolved << e
      e
    }

    polled = []
    retry_queue.poll do |test|
      polled << test
      retry_queue.acknowledge(test)
    end

    assert_equal 1, polled.size
    assert_equal entry, polled.first
    assert_equal 1, resolved.size, "entry_resolver should be called for each entry"
  end

  def test_retry_populate_builds_index_for_eager_mode
    # populate must still work on Retry for RSpec and non-lazy Minitest retries,
    # which call populate to build @index for yielding runnable test objects.
    retry_queue = CI::Queue::Redis::Retry.new(
      TEST_LIST.map(&:id),
      config,
      redis: nil,
    )

    retry_queue.populate(TEST_LIST, random: Random.new(0))

    polled = []
    retry_queue.poll do |test|
      polled << test
      retry_queue.acknowledge(test.id)
    end

    assert_equal TEST_LIST.size, polled.size
    assert polled.all? { |t| t.respond_to?(:id) }, "populate should build index so poll yields test objects"
  end

  def test_retry_queue_poll_with_bare_test_ids
    # Entries without file paths (non-preresolved / eager mode)
    entries = ["ATest#test_foo", "BTest#test_bar"]
    retry_queue = CI::Queue::Redis::Retry.new(
      entries.dup,
      config,
      redis: nil,
    )

    polled = []
    retry_queue.poll do |test|
      polled << test
      retry_queue.acknowledge(test)
    end

    assert_equal 2, polled.size
    assert_equal entries, polled
  end

  def test_retry_queue_requeue_preserves_full_entry
    # Verify that requeue pushes back the original entry (with file path),
    # not just test.id, so entry_resolver can resolve it on the next attempt.
    entry = CI::Queue::QueueEntry.format("ATest#test_foo", "/tmp/a_test.rb")
    requeue_config = CI::Queue::Configuration.new(
      timeout: 0.2,
      build_id: '42',
      worker_id: '1',
      max_requeues: 1,
      requeue_tolerance: 1.0,
      max_consecutive_failures: 10,
    )
    retry_queue = CI::Queue::Redis::Retry.new(
      [entry.dup],
      requeue_config,
      redis: nil,
    )

    resolved_entries = []
    retry_queue.entry_resolver = ->(e) {
      resolved_entries << e
      # Return a mock object with .id that returns the test_id
      Struct.new(:id, :queue_entry).new(CI::Queue::QueueEntry.test_id(e), e)
    }

    poll_count = 0
    retry_queue.poll do |test|
      poll_count += 1
      if poll_count == 1
        retry_queue.report_failure!
        retry_queue.requeue(test.queue_entry) || retry_queue.acknowledge(test.queue_entry)
      else
        retry_queue.report_success!
        retry_queue.acknowledge(test.queue_entry)
      end
    end

    assert_equal 2, poll_count, "Test should be polled twice (original + requeue)"
    # Both resolutions should receive the full JSON entry with file_path
    assert_equal 2, resolved_entries.size
    resolved_entries.each do |e|
      parsed = CI::Queue::QueueEntry.parse(e)
      assert parsed[:file_path],
        "Requeued entry should preserve file path"
    end
  end

  private

  def build_queue
    CI::Queue::Static.new(TEST_LIST.map(&:id), config)
  end
end
