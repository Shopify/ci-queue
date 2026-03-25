local zset_key = KEYS[1]
local processed_key = KEYS[2]
local worker_queue_key = KEYS[3]
local owners_key = KEYS[4]

local current_time = ARGV[1]
local timeout = ARGV[2]

local lost_tests = redis.call('zrangebyscore', zset_key, 0, current_time - timeout)
for _, test in ipairs(lost_tests) do
  if redis.call('sismember', processed_key, test) == 0 then
    redis.call('zadd', zset_key, current_time, test)
    redis.call('lpush', worker_queue_key, test)
    redis.call('hset', owners_key, test, worker_queue_key) -- Take ownership
    return test
  end
end

return nil
