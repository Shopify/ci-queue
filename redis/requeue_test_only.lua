-- Push a single failing test entry back onto the queue from inside a
-- file reservation. Unlike requeue.lua this script:
--   * does NOT enforce a per-entry lease check (the test entry was
--     never individually reserved \u2014 the enclosing file is)
--   * does NOT touch running, owners, or leases (only the file's
--     reservation lives there)
--   * uses processed-tests for the "already terminally recorded" check
--     so success-then-requeue races cannot push a redundant entry
--
-- The new test entry is inserted with the standard requeue offset so
-- another worker picks it up. Per-entry and global requeue caps are
-- enforced exactly like requeue.lua.
--
-- KEYS:
--   processed_tests_key  - SET test entries with terminal results
--   requeues_count_key   - HASH per-entry + ___total___ requeue counts
--   queue_key            - LIST main work queue
--   worker_queue_key     - LIST per-worker requeue tracker (for self-pickup)
--   error_reports_key    - HASH (cleared on requeue)
--   requeued_by_key      - HASH entry -> worker queue key
--
-- ARGV:
--   max_requeues         - per-entry cap
--   global_max_requeues  - global cap
--   entry                - test queue entry to requeue
--   offset               - requeue offset
--   ttl                  - redis_ttl seconds
--
-- Returns: 1 on requeue, 0 if a cap was hit or the entry is already
-- terminally recorded.
local processed_tests_key  = KEYS[1]
local requeues_count_key   = KEYS[2]
local queue_key            = KEYS[3]
local worker_queue_key     = KEYS[4]
local error_reports_key    = KEYS[5]
local requeued_by_key      = KEYS[6]

local max_requeues        = tonumber(ARGV[1])
local global_max_requeues = tonumber(ARGV[2])
local entry               = ARGV[3]
local offset              = tonumber(ARGV[4])
local ttl                 = tonumber(ARGV[5])

-- Already terminally recorded: another worker (or this one on a
-- previous reclaim) recorded a terminal result; do not push again.
if redis.call('sismember', processed_tests_key, entry) == 1 then
  return 0
end

local global_requeues = tonumber(redis.call('hget', requeues_count_key, '___total___'))
if global_requeues and global_requeues >= global_max_requeues then
  return 0
end

local requeues = tonumber(redis.call('hget', requeues_count_key, entry))
if requeues and requeues >= max_requeues then
  return 0
end

redis.call('hincrby', requeues_count_key, '___total___', 1)
redis.call('hincrby', requeues_count_key, entry, 1)

redis.call('hdel', error_reports_key, entry)

local pivot = redis.call('lrange', queue_key, -1 - offset, 0 - offset)[1]
if pivot then
  redis.call('linsert', queue_key, 'BEFORE', pivot, entry)
else
  redis.call('lpush', queue_key, entry)
end

redis.call('hset', requeued_by_key, entry, worker_queue_key)
if ttl and ttl > 0 then
  redis.call('expire', requeued_by_key, ttl)
end

return 1
