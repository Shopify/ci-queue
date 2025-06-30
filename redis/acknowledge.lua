local zset_key = KEYS[1]
local processed_key = KEYS[2]
local owners_key = KEYS[3]
local error_reports_key = KEYS[4]

local test = ARGV[1]
local error = ARGV[2]
local ttl = ARGV[3]
redis.call('zrem', zset_key, test)
redis.call('hdel', owners_key, test)  -- Doesn't matter if it was reclaimed by another workers
local acknowledged = redis.call('sadd', processed_key, test) == 1

if acknowledged and error ~= "" then
  redis.call('hset', error_reports_key, test, error)
  redis.call('expire', error_reports_key, ttl)
end

return acknowledged
