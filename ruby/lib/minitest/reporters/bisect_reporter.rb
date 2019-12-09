# frozen_string_literal: true
require 'minitest/reporters'

module Minitest
  module Reporters
    class BisectReporter < BaseReporter
      include RelativePosition

      def record(test)
        super
        test_name = "#{test.klass}##{test.name}"
        print pad_test(test_name)
        puts pad_mark(result(test).to_s.upcase)
      end
    end
  end
end
