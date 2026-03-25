# frozen_string_literal: true
require 'test_helper'

class CI::Queue::QueueEntryTest < Minitest::Test
  def test_parse_without_file_path
    entry = CI::Queue::QueueEntry.format("FooTest#test_bar", nil)
    parsed = CI::Queue::QueueEntry.parse(entry)
    assert_equal "FooTest#test_bar", parsed[:test_id]
    assert_nil parsed[:file_path]
  end

  def test_parse_with_file_path
    entry = CI::Queue::QueueEntry.format("FooTest#test_bar", "/tmp/foo_test.rb")
    parsed = CI::Queue::QueueEntry.parse(entry)
    assert_equal "FooTest#test_bar", parsed[:test_id]
    assert_equal "/tmp/foo_test.rb", parsed[:file_path]
  end

  def test_format_without_file_path
    entry_nil = CI::Queue::QueueEntry.format("FooTest#test_bar", nil)
    parsed_nil = JSON.parse(entry_nil, symbolize_names: true)
    assert_equal "FooTest#test_bar", parsed_nil[:test_id]
    assert_nil parsed_nil[:file_path]

    entry_empty = CI::Queue::QueueEntry.format("FooTest#test_bar", "")
    parsed_empty = JSON.parse(entry_empty, symbolize_names: true)
    assert_equal "FooTest#test_bar", parsed_empty[:test_id]
    assert_equal "", parsed_empty[:file_path]
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

  def test_test_id_without_file_path
    entry = CI::Queue::QueueEntry.format("FooTest#test_bar", nil)
    assert_equal "FooTest#test_bar", CI::Queue::QueueEntry.test_id(entry)
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
end
