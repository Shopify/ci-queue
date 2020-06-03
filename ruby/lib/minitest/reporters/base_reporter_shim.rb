# frozen_string_literal: true

module Minitest
  module Reporters
    # This module provides compatibility with Minitest::Reporters::BaseReporter
    module BaseReporterShim
      def before_test(*); end
      def after_test(*); end
    end
  end
end
