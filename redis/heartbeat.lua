local zset_key = KEYS[1]
local processed_key = KEYS[2]
local owners_key = KEYS[3]
local worker_queue_key = KEYS[4]

local current_time = ARGV[1]
local queue_entry = ARGV[2]

-- Extract plain test_id for processed check (processed stores plain IDs)
local test_id = queue_entry
local tab_pos = string.find(queue_entry, "\t")
if tab_pos then
  test_id = string.sub(queue_entry, tab_pos + 1)
end

-- already processed, we do not need to bump the timestamp
if redis.call('sismember', processed_key, test_id) == 1 then
  return false
end

-- we're still the owner of the test, we can bump the timestamp
if redis.call('hget', owners_key, queue_entry) == worker_queue_key then
  return redis.call('zadd', zset_key, current_time, queue_entry)
end
