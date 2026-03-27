local zset_key = KEYS[1]
local leases_key = KEYS[2]

local current_time = ARGV[1]
local entry = ARGV[2]
local lease_id = ARGV[3]

-- Only the current lease holder can bump the timestamp.
-- We intentionally do NOT check the processed set. A non-owner worker's
-- acknowledge can add the entry to processed, which would poison the
-- current lease holder's heartbeat if we checked it here.
-- The lease check alone is sufficient — once the lease holder acknowledges,
-- they zrem + hdel the lease, so the heartbeat will naturally stop.
if tostring(redis.call('hget', leases_key, entry)) == lease_id then
  return redis.call('zadd', zset_key, current_time, entry)
end
