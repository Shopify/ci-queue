# frozen_string_literal: true
require 'test_helper'
require 'objspace'

class CI::Queue::Redis::Base::HeartbeatProcessTest < Minitest::Test
  MAX = CI::Queue::Redis::Base::HeartbeatProcess::MAX_RESTART_ATTEMPTS

  # StringIO#write only accepts a single argument on TruffleRuby, so we fake a
  # pipe that supports the multi-argument IO#write signature the production
  # code relies on.
  class FakePipe
    attr_reader :buffer

    def initialize
      @buffer = +"".b
    end

    def write(*parts)
      parts.each { |part| @buffer << part.b }
      @buffer.bytesize
    end
  end

  def setup
    @hp = CI::Queue::Redis::Base::HeartbeatProcess.new(
      'redis://localhost:6379/0',
      'zset', 'owners', 'leases'
    )
    # boot! and restart! must not spawn real processes
    @hp.stubs(:boot!)
    @hp.stubs(:restart!)
  end

  def test_tick_retries_after_pipe_ioerror
    @hp.expects(:send_message).twice.raises(IOError, "closed stream").then.returns(nil)

    @hp.tick!("test_id", "lease_id")
  end

  def test_tick_retries_after_epipe
    @hp.expects(:send_message).twice.raises(Errno::EPIPE).then.returns(nil)

    @hp.tick!("test_id", "lease_id")
  end

  def test_tick_calls_restart_on_pipe_error
    @hp.stubs(:send_message).raises(IOError, "closed stream").then.returns(nil)
    @hp.expects(:restart!).once

    @hp.tick!("test_id", "lease_id")
  end

  def test_tick_raises_after_max_restart_attempts
    @hp.stubs(:send_message).raises(IOError, "closed stream")

    assert_raises(IOError) do
      (MAX + 1).times { @hp.tick!("test_id", "lease_id") }
    end
  end

  def test_restart_counter_resets_after_success
    # Build a sequence: [raise, return] * (MAX+1).
    # Without @restart_attempts = 0 on success, the (MAX+1)th failure would exceed MAX and raise.
    stub = @hp.stubs(:send_message)
    (MAX + 1).times do |i|
      stub = stub.raises(IOError, "closed stream").then.returns(nil)
      stub = stub.then unless i == MAX
    end

    (MAX + 1).times { @hp.tick!("test_id", "lease_id") }
  end

  def test_tick_does_not_allocate_tick_marker_string
    @hp.instance_variable_set(:@pipe, FakePipe.new)
    @hp.tick!("test_id", "lease_id") # warm up any one-time caches

    ObjectSpace.trace_object_allocations_start
    begin
      @hp.tick!("test_id", "lease_id")
    ensure
      ObjectSpace.trace_object_allocations_stop
    end

    tick_allocations = []
    ObjectSpace.each_object(String) do |s|
      next unless s == "tick!"
      file = ObjectSpace.allocation_sourcefile(s)
      next unless file # already-allocated strings have no source
      tick_allocations << [file, ObjectSpace.allocation_sourceline(s)]
    end

    assert_empty tick_allocations,
      "A 'tick!' String was allocated per heartbeat tick — the command marker should be cached as a frozen String"
  ensure
    ObjectSpace.trace_object_allocations_clear
  end

  def test_tick_sends_valid_tick_payload
    pipe = FakePipe.new
    @hp.instance_variable_set(:@pipe, pipe)

    @hp.tick!("test_id", "lease_id")

    raw = pipe.buffer
    header_size = [0].pack("L").bytesize
    size = raw.byteslice(0, header_size).unpack1("L")
    payload = raw.byteslice(header_size, size)

    assert_equal ["tick!", { "id" => "test_id", "lease" => "lease_id" }], JSON.parse(payload)
  end
end
