local zset_key = KEYS[1]
local processed_key = KEYS[2]
local owners_key = KEYS[3]
local error_reports_key = KEYS[4]

local queue_entry = ARGV[1]
local error = ARGV[2]
local ttl = ARGV[3]

-- Queue entries may be "file_path\ttest_id" (streaming mode) or plain "test_id".
-- Extract the plain test_id for processed/error-reports keys (consumed by reporters),
-- but use the full queue_entry for running/owners (must match what reserve stored).
local test_id = queue_entry
local tab_pos = string.find(queue_entry, "\t")
if tab_pos then
  test_id = string.sub(queue_entry, tab_pos + 1)
end

redis.call('zrem', zset_key, queue_entry)
redis.call('hdel', owners_key, queue_entry)  -- Doesn't matter if it was reclaimed by another workers
local acknowledged = redis.call('sadd', processed_key, test_id) == 1

if acknowledged and error ~= "" then
  redis.call('hset', error_reports_key, test_id, error)
  redis.call('expire', error_reports_key, ttl)
end

return acknowledged
