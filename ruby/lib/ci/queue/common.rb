module CI
  module Queue
    module Common
      attr_reader :config

      def flaky?(test)
        @config.flaky?(test)
      end

      def report_failure!
        config.circuit_breaker.report_failure!
      end

      def report_success!
        config.circuit_breaker.report_success!
      end
    end
  end
end
