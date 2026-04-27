# frozen_string_literal: true
require 'test_helper'

class CI::Queue::QueueEntryTest < Minitest::Test
  def test_format_raises_without_file_path
    assert_raises(ArgumentError) { CI::Queue::QueueEntry.format("FooTest#test_bar", nil) }
    assert_raises(ArgumentError) { CI::Queue::QueueEntry.format("FooTest#test_bar", "") }
  end

  def test_parse_with_file_path
    entry = CI::Queue::QueueEntry.format("FooTest#test_bar", "/tmp/foo_test.rb")
    parsed = CI::Queue::QueueEntry.parse(entry)
    assert_equal "FooTest#test_bar", parsed[:test_id]
    assert_equal "/tmp/foo_test.rb", parsed[:file_path]
  end

  def test_format_with_file_path
    entry = CI::Queue::QueueEntry.format("FooTest#test_bar", "/tmp/foo_test.rb")
    parsed = JSON.parse(entry, symbolize_names: true)
    assert_equal "FooTest#test_bar", parsed[:test_id]
    assert_equal "/tmp/foo_test.rb", parsed[:file_path]
  end

  def test_parse_with_pipe_in_test_name
    test_id = "FooTest#test_status=[published_|_visible]_tag:elasticsearch:true"
    entry = CI::Queue::QueueEntry.format(test_id, "/tmp/foo_test.rb")
    parsed = CI::Queue::QueueEntry.parse(entry)
    assert_equal test_id, parsed[:test_id]
    assert_equal "/tmp/foo_test.rb", parsed[:file_path]
  end

  def test_parse_with_tab_in_test_name
    test_id = "FooTest#test_xss_<IMG SRC=\"jav\tascript:alert('XSS');\">"
    entry = CI::Queue::QueueEntry.format(test_id, "/tmp/foo_test.rb")
    parsed = CI::Queue::QueueEntry.parse(entry)
    assert_equal test_id, parsed[:test_id]
    assert_equal "/tmp/foo_test.rb", parsed[:file_path]
  end

  def test_round_trip_preserves_test_id
    test_id = "FooTest#test_bar"
    file_path = "/tmp/foo_test.rb"
    entry = CI::Queue::QueueEntry.format(test_id, file_path)
    parsed = CI::Queue::QueueEntry.parse(entry)
    assert_equal test_id, parsed[:test_id]
    assert_equal file_path, parsed[:file_path]
  end

  def test_test_id_with_file_path
    entry = CI::Queue::QueueEntry.format("FooTest#test_bar", "/tmp/foo_test.rb")
    assert_equal "FooTest#test_bar", CI::Queue::QueueEntry.test_id(entry)
  end

  def test_test_id_with_tab_in_test_name
    test_id = "FooTest#test_xss_<IMG SRC=\"jav\tascript:alert('XSS');\">"
    entry = CI::Queue::QueueEntry.format(test_id, "/tmp/foo_test.rb")
    assert_equal test_id, CI::Queue::QueueEntry.test_id(entry)
  end

  def test_encode_decode_load_error
    error = StandardError.new("boom")
    error.set_backtrace(["/tmp/test.rb:10"])
    encoded = CI::Queue::QueueEntry.encode_load_error("/tmp/test.rb", error)
    assert CI::Queue::QueueEntry.load_error_payload?(encoded)

    payload = CI::Queue::QueueEntry.decode_load_error(encoded)
    assert_equal "/tmp/test.rb", payload['file_path']
    assert_equal "StandardError", payload['error_class']
    assert_equal "boom", payload['error_message']
    assert_equal ["/tmp/test.rb:10"], payload['backtrace']
  end

  # ---------------------------------------------------------------------------
  # File-affinity work-unit entries
  # ---------------------------------------------------------------------------

  def test_format_file_raises_without_file_path
    assert_raises(ArgumentError) { CI::Queue::QueueEntry.format_file(nil) }
    assert_raises(ArgumentError) { CI::Queue::QueueEntry.format_file("") }
  end

  def test_format_file_round_trip
    entry = CI::Queue::QueueEntry.format_file("/tmp/foo_test.rb")
    parsed = CI::Queue::QueueEntry.parse(entry)
    assert_equal "file", parsed[:type]
    assert_equal "/tmp/foo_test.rb", parsed[:file_path]
    assert_nil parsed[:test_id]
  end

  def test_format_file_expands_path
    entry = CI::Queue::QueueEntry.format_file("foo_test.rb")
    assert_equal File.expand_path("foo_test.rb"), CI::Queue::QueueEntry.file_path(entry)
  end

  def test_file_entry_predicate
    file_entry = CI::Queue::QueueEntry.format_file("/tmp/foo_test.rb")
    test_entry = CI::Queue::QueueEntry.format("FooTest#test_bar", "/tmp/foo_test.rb")

    assert CI::Queue::QueueEntry.file_entry?(file_entry)
    refute CI::Queue::QueueEntry.file_entry?(test_entry)
    refute CI::Queue::QueueEntry.test_entry?(file_entry)
    assert CI::Queue::QueueEntry.test_entry?(test_entry)

    assert_equal :file, CI::Queue::QueueEntry.entry_type(file_entry)
    assert_equal :test, CI::Queue::QueueEntry.entry_type(test_entry)
  end

  def test_file_entry_predicate_handles_garbage_input
    refute CI::Queue::QueueEntry.file_entry?(nil)
    refute CI::Queue::QueueEntry.file_entry?("")
    refute CI::Queue::QueueEntry.file_entry?("not json")
    assert_equal :test, CI::Queue::QueueEntry.entry_type("not json")
  end

  def test_file_path_for_file_and_test_entries
    file_entry = CI::Queue::QueueEntry.format_file("/tmp/foo_test.rb")
    test_entry = CI::Queue::QueueEntry.format("FooTest#test_bar", "/tmp/foo_test.rb")

    assert_equal "/tmp/foo_test.rb", CI::Queue::QueueEntry.file_path(file_entry)
    assert_equal "/tmp/foo_test.rb", CI::Queue::QueueEntry.file_path(test_entry)
  end

  # ---------------------------------------------------------------------------
  # Reservation key
  # ---------------------------------------------------------------------------

  def test_reservation_key_for_test_entry_is_test_id
    entry = CI::Queue::QueueEntry.format("FooTest#test_bar", "/tmp/foo_test.rb")
    assert_equal "FooTest#test_bar", CI::Queue::QueueEntry.reservation_key(entry)
  end

  def test_reservation_key_for_file_entry_is_non_nil_and_unique
    a = CI::Queue::QueueEntry.format_file("/tmp/foo_test.rb")
    b = CI::Queue::QueueEntry.format_file("/tmp/bar_test.rb")

    refute_nil CI::Queue::QueueEntry.reservation_key(a)
    refute_nil CI::Queue::QueueEntry.reservation_key(b)
    refute_equal CI::Queue::QueueEntry.reservation_key(a), CI::Queue::QueueEntry.reservation_key(b)
    assert_match %r{\Afile:/tmp/foo_test\.rb\z}, CI::Queue::QueueEntry.reservation_key(a)
  end

  def test_reservation_key_falls_back_to_entry_for_non_json
    assert_equal "raw-entry", CI::Queue::QueueEntry.reservation_key("raw-entry")
  end

  # ---------------------------------------------------------------------------
  # Backwards compatibility: test entries must remain byte-stable.
  # ---------------------------------------------------------------------------

  def test_test_entry_format_does_not_include_type_field
    entry = CI::Queue::QueueEntry.format("FooTest#test_bar", "/tmp/foo_test.rb")
    refute_match(/"type"/, entry, "test entries must remain byte-identical to pre-file-affinity format")
  end
end
