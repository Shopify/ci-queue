#!/usr/bin/env ruby

require_relative 'dummy_test'

require 'minitest/queue'
require 'minitest/reporters/queue_reporter'
require 'ci/queue'
require 'ci/queue/redis'

Minitest::Reporters.use!([Minitest::Reporters::QueueReporter.new])

Minitest.queue = CI::Queue::Redis.new(
  "redis://#{ENV.fetch('REDIS_HOST', 'localhost')}/7",
  CI::Queue::Configuration.new(
    build_id: '1',
    worker_id: '1',
    timeout: 1,
    max_requeues: 1,
    requeue_tolerance: 1.0,
  ),
)

if ARGV.first == 'retry'
  Minitest.queue = Minitest.queue.retry_queue
end

Minitest.queue.populate(Minitest.loaded_tests, &:to_s)
