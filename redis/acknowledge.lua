local zset_key = KEYS[1]
local processed_key = KEYS[2]
local owners_key = KEYS[3]
local error_reports_key = KEYS[4]
local requeued_by_key = KEYS[5]
local leases_key = KEYS[6]

local entry = ARGV[1]
local error = ARGV[2]
local ttl = ARGV[3]
local lease_id = ARGV[4]

-- Only the current lease holder can remove the entry from the running set.
-- If the lease was transferred (e.g. via reserve_lost), the stale worker
-- must not remove the running entry — that would let the supervisor think
-- the queue is exhausted while the new lease holder is still processing.
if tostring(redis.call('hget', leases_key, entry)) == lease_id then
  redis.call('zrem', zset_key, entry)
  redis.call('hdel', owners_key, entry)
  redis.call('hdel', leases_key, entry)
end

redis.call('hdel', requeued_by_key, entry)
local acknowledged = redis.call('sadd', processed_key, entry) == 1

if acknowledged and error ~= "" then
  redis.call('hset', error_reports_key, entry, error)
  redis.call('expire', error_reports_key, ttl)
end

return acknowledged
