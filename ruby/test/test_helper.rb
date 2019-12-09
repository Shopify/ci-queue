# frozen_string_literal: true
require 'simplecov'
SimpleCov.start

$LOAD_PATH.unshift File.expand_path('../../lib', __FILE__)
ENV['PATH'] = "#{File.expand_path('../../exe/', __FILE__)}:#{ENV['PATH']}"

require 'ci/queue'
require 'ci/queue/redis'
require 'minitest/queue'
require 'minitest/autorun'

Minitest::Reporters.use!([Minitest::Reporters::SpecReporter.new])

require 'tmpdir'
require 'thread'
require 'stringio'

Dir[File.expand_path('../support/**/*.rb', __FILE__)].sort.each do |file|
  require file
end
