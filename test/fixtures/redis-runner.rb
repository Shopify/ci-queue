#!/usr/bin/env ruby

require_relative 'dummy_test'

require 'minitest/queue'
require 'ci/queue/redis'

Minitest.queue = CI::Queue::Redis.new(
  Minitest.loaded_tests,
  redis: ::Redis.new(db: 7),
  build_id: 1,
  worker_id: 1,
  timeout: 1,
  max_requeues: 2,
  requeue_tolerance: 0.5,
)

if ARGV.first == 'retry'
  Minitest.queue = Minitest.queue.retry_queue(
    max_requeues: 2,
    requeue_tolerance: 0.5,
  )
end
