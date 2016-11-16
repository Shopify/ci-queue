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
  global_max_requeues: 20
)

if ARGV.first == 'retry'
  Minitest.queue = Minitest.queue.retry_queue(
    max_requeues: 2,
    global_max_requeues: 20,
  )
end
