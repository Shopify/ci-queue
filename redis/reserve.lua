local queue_key = KEYS[1]
local zset_key = KEYS[2]
local processed_key = KEYS[3]
local worker_queue_key = KEYS[4]
local owners_key = KEYS[5]

local current_time = ARGV[1]

local test = redis.call('rpop', queue_key)
if test then
  redis.call('zadd', zset_key, current_time, test)
  redis.call('lpush', worker_queue_key, test)
  redis.call('hset', owners_key, test, worker_queue_key)
  return test
else
  return nil
end
