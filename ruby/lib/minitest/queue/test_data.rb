# frozen_string_literal: true
require 'minitest/reporters'
require 'fileutils'

module Minitest
  module Queue
    class TestData
      attr_reader :namespace, :test_index

      def initialize(test:, index:, namespace:, base_path:)
        @test = test
        @base_path = base_path
        @namespace = namespace
        @test_index = index
      end

      def test_id
        "#{test_suite}##{test_name}"
      end

      def test_name
        @test.name
      end

      def test_suite
        @test.klass
      end

      def test_retried
        @test.requeued?
      end

      def test_result
        if @test.passed?
          'success'
        elsif !@test.requeued? && @test.skipped?
          'skipped'
        elsif @test.error?
          'error'
        elsif @test.failure
          'failure'
        else
          'undefined'
        end
      end

      def test_assertions
        @test.assertions
      end

      def test_duration
        @test.time
      end

      def test_file_path
        path = @test.source_location.first
        relative_path_for(path)
      end

      def test_file_line_number
        @test.source_location.last
      end

      # Error class only considers failures wheras the other error fields also consider skips
      def error_class
        return nil unless @test.failure

        @test.failure.error.class.name
      end

      def error_message
        return nil unless @test.failure

        @test.failure.message
      end

      def error_file_path
        return nil unless @test.failure

        path = error_location(@test.failure).first
        relative_path_for(path)
      end

      def error_file_number
        return nil unless @test.failure

        error_location(@test.failure).last
      end

      def to_h
        {
          namespace: namespace,
          test_id: test_id,
          test_name: test_name,
          test_suite: test_suite,
          test_result: test_result,
          test_index: test_index,
          test_result_ignored: @test.flaked?,
          test_retried: test_retried,
          test_assertions: test_assertions,
          test_duration: test_duration,
          test_file_path: test_file_path,
          test_file_line_number: test_file_line_number,
          error_class: error_class,
          error_message: error_message,
          error_file_path: error_file_path,
          error_file_number: error_file_number,
        }
      end

      private

      def relative_path_for(path)
        file_path = Pathname.new(path)
        base_path = Pathname.new(@base_path)
        file_path.relative_path_from(base_path)
      end

      def error_location(exception)
        @error_location ||= begin
          last_before_assertion = ''
          exception.backtrace.reverse_each do |s|
            break if s =~ /in .(assert|refute|flunk|pass|fail|raise|must|wont)/

            last_before_assertion = s
          end
          path = last_before_assertion.sub(/:in .*$/, '')
          # the path includes the linenumber at the end,
          # which is seperated by a :
          # rpartition splits the string at the last occurence of :
          result = path.rpartition(':')
          # We return [path, linenumber] here
          [result.first, result.last.to_i]
        end
      end
    end
  end
end
