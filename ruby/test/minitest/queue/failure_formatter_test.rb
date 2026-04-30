# frozen_string_literal: true

require 'test_helper'

module Minitest::Queue
  class FailureFormatterTest < Minitest::Test
    include ReporterTestHelper

    def test_to_s_and_to_h_with_valid_utf8
      test = result('test_valid', failure: "assertion failed: expected \u2603")
      formatter = FailureFormatter.new(test)

      assert_predicate(formatter.to_s, :valid_encoding?)
      assert_includes(formatter.to_s, "assertion failed: expected \u2603")
      assert(JSON.dump(formatter.to_h))
    end

    def test_to_s_and_to_h_with_ascii_8bit_failure
      test = result('test_json', failure: "\xD6".b)
      formatter = FailureFormatter.new(test)

      assert_predicate(formatter.to_s, :valid_encoding?)
      assert(JSON.dump(formatter.to_h))
    end

    def test_to_s_and_to_h_with_utf8_tagged_invalid_bytes
      # Mirror the production trigger: a UTF-8-tagged string containing invalid byte
      # sequences. encode!(UTF_8, ...) is a no-op when source == dest encoding, so
      # without scrub! these bytes pass through and crash JSON.dump.
      invalid_utf8 = "boom \xE1\x02\xFF tail".dup.force_encoding(Encoding::UTF_8)
      refute_predicate(invalid_utf8, :valid_encoding?)

      test = result('test_json_utf8_tagged', failure: invalid_utf8)
      formatter = FailureFormatter.new(test)

      assert_predicate(formatter.to_s, :valid_encoding?)
      assert_includes(formatter.to_s, "tail")
      assert(JSON.dump(formatter.to_h))
    end

    def test_to_s_and_to_h_with_iso_8859_1_failure
      # encode! transcodes non-UTF-8 sources; verify the character is preserved.
      iso_message = "expected \xD6sterreich".dup.force_encoding(Encoding::ISO_8859_1)
      test = result('test_iso', failure: iso_message)
      formatter = FailureFormatter.new(test)

      assert_predicate(formatter.to_s, :valid_encoding?)
      assert_includes(formatter.to_s, "\u00D6sterreich")
      assert(JSON.dump(formatter.to_h))
    end

    def test_to_s_and_to_h_with_unexpected_error_containing_invalid_bytes
      error = StandardError.new("binary payload \xC0\xFF".b)
      error.set_backtrace(["test.rb:1:in `test'"])
      unexpected = Minitest::UnexpectedError.new(error)

      test = result('test_unexpected', failure: unexpected)
      formatter = FailureFormatter.new(test)

      assert_predicate(formatter.to_s, :valid_encoding?)
      assert_includes(formatter.to_s, "StandardError")
      assert(JSON.dump(formatter.to_h))
    end
  end
end
