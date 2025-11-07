# frozen_string_literal: true

require 'test_helper'

module Minitest::Queue
  class FailureFormatterTest < Minitest::Test
    include ReporterTestHelper

    def test_failure_formatter_to_h_can_be_json_dumped
      test = result('test_json', failure: "\xD6".b)

      formatter = FailureFormatter.new(test)

      assert JSON.dump(formatter.to_h)
    end
  end
end
