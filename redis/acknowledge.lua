local zset_key = KEYS[1]
local processed_key = KEYS[2]
local owners_key = KEYS[3]
local error_reports_key = KEYS[4]

local entry = ARGV[1]
local test_id = ARGV[2]
local error = ARGV[3]
local ttl = ARGV[4]
redis.call('zrem', zset_key, entry)
redis.call('hdel', owners_key, entry)  -- Doesn't matter if it was reclaimed by another workers
local acknowledged = redis.call('sadd', processed_key, test_id) == 1

if acknowledged and error ~= "" then
  redis.call('hset', error_reports_key, test_id, error)
  redis.call('expire', error_reports_key, ttl)
end

return acknowledged
