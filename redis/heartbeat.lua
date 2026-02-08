local zset_key = KEYS[1]
local processed_key = KEYS[2]
local owners_key = KEYS[3]
local worker_queue_key = KEYS[4]

local current_time = ARGV[1]
local entry = ARGV[2]
local entry_delimiter = ARGV[3]

local function test_id_from_entry(value)
  if entry_delimiter then
    local pos = string.find(value, entry_delimiter, 1, true)
    if pos then
      return string.sub(value, 1, pos - 1)
    end
  end
  return value
end

local test_id = test_id_from_entry(entry)

-- already processed, we do not need to bump the timestamp
if redis.call('sismember', processed_key, test_id) == 1 then
  return false
end

-- we're still the owner of the test, we can bump the timestamp
if redis.call('hget', owners_key, entry) == worker_queue_key then
  return redis.call('zadd', zset_key, current_time, entry)
end
