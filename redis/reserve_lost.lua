local zset_key = KEYS[1]
local processed_key = KEYS[2]
local worker_queue_key = KEYS[3]
local owners_key = KEYS[4]

local current_time = ARGV[1]
local timeout = ARGV[2]

local function test_id_from_entry(entry)
  local delimiter = string.find(entry, "|", 1, true)
  if delimiter then
    return string.sub(entry, 1, delimiter - 1)
  end
  return entry
end

local lost_tests = redis.call('zrangebyscore', zset_key, 0, current_time - timeout)
for _, test in ipairs(lost_tests) do
  local test_id = test_id_from_entry(test)
  if redis.call('sismember', processed_key, test_id) == 0 then
    redis.call('zadd', zset_key, current_time, test)
    redis.call('lpush', worker_queue_key, test)
    redis.call('hset', owners_key, test, worker_queue_key) -- Take ownership
    return test
  end
end

return nil
