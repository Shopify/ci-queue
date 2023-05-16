# frozen_string_literal: true
$LOAD_PATH.unshift File.expand_path('../../../lib', __FILE__)

if ENV['MARSHAL']
  Minitest::Queue::ErrorReport.coder = Marshal
end

require 'minitest/autorun'
require_relative './backtrace_filters'

Minitest.backtrace_filter = BacktraceFilters.new(
  Minitest.backtrace_filter
)
