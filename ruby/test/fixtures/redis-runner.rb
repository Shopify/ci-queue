#!/usr/bin/env ruby

require_relative 'dummy_test'

require 'minitest/queue'
require 'minitest/reporters/queue_reporter'
require 'ci/queue'
require 'ci/queue/redis'

Minitest::Reporters.use!([Minitest::Reporters::QueueReporter.new])

Minitest.queue = CI::Queue::Redis.new(
  Minitest.loaded_tests,
  redis: ::Redis.new(host: ENV.fetch('REDIS_HOST', nil), db: 7, timeout: 1),
  build_id: 1,
  worker_id: 1,
  timeout: 1,
  max_requeues: 1,
  requeue_tolerance: 1.0,
)

if ARGV.first == 'retry'
  Minitest.queue = Minitest.queue.retry_queue(
    max_requeues: 1,
    requeue_tolerance: 1.0,
  )
end
