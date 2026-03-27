local zset_key = KEYS[1]
local processed_key = KEYS[2]
local worker_queue_key = KEYS[3]
local owners_key = KEYS[4]
local leases_key = KEYS[5]
local lease_counter_key = KEYS[6]

local current_time = ARGV[1]
local timeout = ARGV[2]

local lost_tests = redis.call('zrangebyscore', zset_key, 0, current_time - timeout)
for _, test in ipairs(lost_tests) do
  if redis.call('sismember', processed_key, test) == 0 then
    local lease = redis.call('incr', lease_counter_key)
    redis.call('zadd', zset_key, current_time, test)
    redis.call('lpush', worker_queue_key, test)
    redis.call('hset', owners_key, test, worker_queue_key)
    redis.call('hset', leases_key, test, lease)
    return {test, tostring(lease)}
  else
    -- Test is already processed but still in running (stale). This can happen when
    -- a non-owner worker acknowledged the test (marking it processed) but could not
    -- remove it from running due to the lease guard. Clean it up.
    redis.call('zrem', zset_key, test)
    redis.call('hdel', owners_key, test)
    redis.call('hdel', leases_key, test)
  end
end

return nil
