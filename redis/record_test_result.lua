-- Record a per-test terminal result for a test that ran inside a file
-- reservation (file-affinity mode). Unlike acknowledge.lua, this script
-- never touches the running set, leases, or owners — the test entry was
-- never individually reserved (the file is). It also writes to a separate
-- `processed-tests` set so per-test idempotency on mid-file reclaim is
-- independent of file-level acknowledgement.
--
-- KEYS:
--   processed_tests_key      - SET of test entries with terminal results
--   error_reports_key        - HASH test_entry -> error payload
--   requeues_count_key       - HASH (only consulted on success path)
--   error_report_deltas_key  - HASH test_entry -> stat-correction payload
--
-- ARGV:
--   status   - "success" or "failure"
--   entry    - test queue entry (JSON)
--   payload  - failure error payload, "" on success
--   ttl      - redis_ttl seconds
--
-- Returns:
--   failure: { added (1 if first ack, 0 otherwise), 0, false, false }
--   success: { added, error_reports_deleted_count, requeues_count or false,
--              delta_json or false }
local processed_tests_key     = KEYS[1]
local error_reports_key       = KEYS[2]
local requeues_count_key      = KEYS[3]
local error_report_deltas_key = KEYS[4]

local status  = ARGV[1]
local entry   = ARGV[2]
local payload = ARGV[3]
local ttl     = tonumber(ARGV[4])

local function expire(key, seconds)
  if seconds and seconds > 0 then
    redis.call('expire', key, seconds)
  end
end

if status == 'failure' then
  local first = redis.call('sadd', processed_tests_key, entry) == 1
  if first then
    redis.call('hset', error_reports_key, entry, payload)
    expire(processed_tests_key, ttl)
    expire(error_reports_key, ttl)
    return {1, 0, false, false}
  end
  return {0, 0, false, false}
end

-- success path
local added    = redis.call('sadd', processed_tests_key, entry)
local deleted  = redis.call('hdel', error_reports_key, entry)
local requeues = redis.call('hget', requeues_count_key, entry)
local delta    = redis.call('hget', error_report_deltas_key, entry)
expire(processed_tests_key, ttl)
return {added, deleted, requeues or false, delta or false}
