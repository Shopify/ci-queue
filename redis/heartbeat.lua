-- @include _entry_helpers

local zset_key = KEYS[1]
local processed_key = KEYS[2]
local owners_key = KEYS[3]
local worker_queue_key = KEYS[4]

local current_time = ARGV[1]
local entry = ARGV[2]
local entry_delimiter = ARGV[3]

local test_id = test_id_from_entry(entry, entry_delimiter)

-- already processed, we do not need to bump the timestamp
if redis.call('sismember', processed_key, test_id) == 1 then
  return false
end

-- we're still the owner of the test, we can bump the timestamp
if redis.call('hget', owners_key, entry) == worker_queue_key then
  return redis.call('zadd', zset_key, current_time, entry)
end
