local zset_key = KEYS[1]
local processed_key = KEYS[2]
local owners_key = KEYS[3]
local error_reports_key = KEYS[4]
local requeues_count_key = KEYS[5]
local flaky_reports_key = KEYS[6]

local test = ARGV[1]
local error_report = ARGV[2]
local ttl = ARGV[3]
local skip_flaky_record = ARGV[4]
redis.call('zrem', zset_key, test)
redis.call('hdel', owners_key, test)  -- Doesn't matter if it was reclaimed by another workers

local acknowledged = redis.call('sadd', processed_key, test)

if error_report ~= "" and acknowledged then -- we only record the error if the test was acknowledged by us
  redis.call('hset', error_reports_key, test, error_report)
  redis.call('expire', error_reports_key, ttl)
else -- we record the error even if we didn't acknowledge the test
  local deleted_count = tonumber(redis.call('hdel', error_reports_key, test))
  local requeued_count = tonumber(redis.call('hget', requeues_count_key, test))

  if skip_flaky_record == "false" and ((deleted_count and deleted_count > 0) or (requeued_count and requeued_count > 0)) then
    redis.call('sadd', flaky_reports_key, test)
    redis.call('expire', flaky_reports_key, ttl)
  end
end

return acknowledged
