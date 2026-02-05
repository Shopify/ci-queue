local zset_key = KEYS[1]
local processed_key = KEYS[2]
local worker_queue_key = KEYS[3]
local owners_key = KEYS[4]

local current_time = ARGV[1]
local timeout = ARGV[2]

local lost_tests = redis.call('zrangebyscore', zset_key, 0, current_time - timeout)
for _, queue_entry in ipairs(lost_tests) do
  -- Extract plain test_id for processed check (processed stores plain IDs)
  local test_id = queue_entry
  local tab_pos = string.find(queue_entry, "\t")
  if tab_pos then
    test_id = string.sub(queue_entry, tab_pos + 1)
  end

  if redis.call('sismember', processed_key, test_id) == 0 then
    redis.call('zadd', zset_key, current_time, queue_entry)
    redis.call('lpush', worker_queue_key, queue_entry)
    redis.call('hset', owners_key, queue_entry, worker_queue_key) -- Take ownership
    return queue_entry
  end
end

return nil
