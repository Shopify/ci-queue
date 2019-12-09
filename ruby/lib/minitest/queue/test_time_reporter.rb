# frozen_string_literal: true
require 'minitest/reporters'

module Minitest
  module Queue
    class TestTimeReporter < Minitest::Reporters::BaseReporter
      include ::CI::Queue::OutputHelpers

      def initialize(build:, limit: nil, percentile: nil, **options)
        super(options)
        @test_time_hash = build.fetch
        @limit = limit
        @percentile = percentile
        @success = true
      end

      def report
        return if limit.nil? || test_time_hash.empty?

        puts '+++ Test Time Report'

        if offending_tests.empty?
          msg = "The #{humanized_percentile} of test execution time is within #{limit} milliseconds."
          puts green(msg)
          return
        end

        @success = false
        puts <<~EOS
          #{red("Detected #{offending_tests.size} test(s) over the desired time limit.")}
          Please make them faster than #{limit}ms in the #{humanized_percentile} percentile.
        EOS
        offending_tests.each do |test_name, duration|
          puts "#{red(test_name)}: #{duration}ms"
        end
      end

      def success?
        @success
      end

      def record(*)
        raise NotImplementedError
      end

      private

      attr_reader :test_time_hash, :limit, :percentile

      def humanized_percentile
        percentile_in_percentage = percentile * 100
        "#{percentile_in_percentage.to_i}th"
      end

      def offending_tests
        @offending_tests ||= begin
          test_time_hash.each_with_object({}) do |(test_name, durations), offenders|
            duration = calculate_percentile(durations)
            next if duration <= limit
            offenders[test_name] = duration
          end
        end
      end

      def calculate_percentile(array)
        array.sort[(percentile * array.length).ceil - 1]
      end
    end
  end
end
