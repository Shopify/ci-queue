require 'simplecov'
SimpleCov.start

$LOAD_PATH.unshift File.expand_path('../../lib', __FILE__)

require 'ci/queue'
require 'ci/queue/redis'
require 'minitest/queue'
require 'minitest/reporters/redis_reporter'
require 'minitest/autorun'

require 'thread'
require 'stringio'

Dir[File.expand_path('../support/**/*.rb', __FILE__)].sort.each do |file|
  require file
end
