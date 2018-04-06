module CI
  module Queue
    module Common
      def flaky?(test)
        @config.flaky?(test)
      end

      def report_failure!
        config.circuit_breaker.report_failure!
      end

      def report_success!
        config.circuit_breaker.report_success!
      end

      private

      attr_reader :config
    end
  end
end
