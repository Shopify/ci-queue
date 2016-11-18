$LOAD_PATH.unshift File.expand_path('../../../lib', __FILE__)

require 'minitest/reporters'
Minitest::Reporters.use!([Minitest::Reporters::DefaultReporter.new])
require 'minitest/autorun'

Minitest.backtrace_filter.add_filter(%r{lib/ci/queue})
