require 'simplecov'
SimpleCov.start

$LOAD_PATH.unshift File.expand_path('../../lib', __FILE__)

require 'ci/queue'
require 'ci/queue/redis'
require 'minitest/autorun'

require 'thread'
Dir[File.expand_path('../support/**/*.rb', __FILE__)].sort.each do |file|
  require file
end
