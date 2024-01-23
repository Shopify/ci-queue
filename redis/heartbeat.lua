local zset_key = KEYS[1]
local processed_key = KEYS[2]
local owners_key = KEYS[3]
local worker_queue_key = KEYS[4]

local current_time = ARGV[1]
local test = ARGV[2]

-- already processed, we do not need to bump the timestamp
if redis.call('sismember', processed_key, test) == 1 then
  return false
end

-- we're still the owner of the test, we can bump the timestamp
if redis.call('hget', owners_key, test) == worker_queue_key then
  return redis.call('zadd', zset_key, current_time, test)
end
