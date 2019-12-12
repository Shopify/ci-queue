# frozen_string_literal: true
require 'minitest/reporters'
require 'fileutils'
require 'json'

require 'minitest/queue/test_data'

module Minitest
  module Queue
    class TestDataReporter < Minitest::Reporters::BaseReporter
      def initialize(report_path: 'log/test_data.json', base_path: nil, namespace: '')
        super({})
        @report_path = File.absolute_path(report_path)
        @base_path = base_path || Dir.pwd
        @namespace = namespace || ''
      end

      def report
        super

        result = tests.map.with_index do |test, index|
          Queue::TestData.new(test: test, index: index,
                              base_path: @base_path, namespace: @namespace).to_h
        end.to_json

        dirname = File.dirname(@report_path)
        FileUtils.mkdir_p(dirname)
        File.open(@report_path, 'w+') { |file| file << result }
      end
    end
  end
end
