# frozen_string_literal: true
module CI
  module Queue
    module Common
      attr_reader :config

      # to override in classes including this module
      CONNECTION_ERRORS = [].freeze

      def retrying?
        false
      end

      def flaky?(test)
        @config.flaky?(test)
      end

      def report_failure!
        config.circuit_breakers.each(&:report_failure!)
      end

      def report_success!
        config.circuit_breakers.each(&:report_success!)
      end

      def rescue_connection_errors(handler = ->(err) { nil })
        yield
      rescue *self::class::CONNECTION_ERRORS => err
        handler.call(err)
      end
    end
  end
end
