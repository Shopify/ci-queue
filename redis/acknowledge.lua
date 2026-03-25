local zset_key = KEYS[1]
local processed_key = KEYS[2]
local owners_key = KEYS[3]
local error_reports_key = KEYS[4]
local requeued_by_key = KEYS[5]

local entry = ARGV[1]
local error = ARGV[2]
local ttl = ARGV[3]
redis.call('zrem', zset_key, entry)
redis.call('hdel', owners_key, entry)  -- Doesn't matter if it was reclaimed by another workers
redis.call('hdel', requeued_by_key, entry)
local acknowledged = redis.call('sadd', processed_key, entry) == 1

if acknowledged and error ~= "" then
  redis.call('hset', error_reports_key, entry, error)
  redis.call('expire', error_reports_key, ttl)
end

return acknowledged
