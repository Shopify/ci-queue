$LOAD_PATH.unshift File.expand_path('../../../lib', __FILE__)

require 'minitest/reporters/queue_reporter'
Minitest::Reporters.use!(Minitest.queue.minitest_reporters)
require 'minitest/autorun'

Minitest.backtrace_filter.add_filter(%r{lib/ci/queue})
