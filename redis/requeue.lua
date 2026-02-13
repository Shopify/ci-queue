local processed_key = KEYS[1]
local requeues_count_key = KEYS[2]
local queue_key = KEYS[3]
local zset_key = KEYS[4]
local worker_queue_key = KEYS[5]
local owners_key = KEYS[6]
local error_reports_key = KEYS[7]

local max_requeues = tonumber(ARGV[1])
local global_max_requeues = tonumber(ARGV[2])
local entry = ARGV[3]
local test_id = ARGV[4]
local offset = ARGV[5]

if redis.call('hget', owners_key, entry) == worker_queue_key then
   redis.call('hdel', owners_key, entry)
end

if redis.call('sismember', processed_key, test_id) == 1 then
  return false
end

local global_requeues = tonumber(redis.call('hget', requeues_count_key, '___total___'))
if global_requeues and global_requeues >= tonumber(global_max_requeues) then
  return false
end

local requeues = tonumber(redis.call('hget', requeues_count_key, test_id))
if requeues and requeues >= max_requeues then
  return false
end

redis.call('hincrby', requeues_count_key, '___total___', 1)
redis.call('hincrby', requeues_count_key, test_id, 1)

redis.call('hdel', error_reports_key, test_id)

local pivot = redis.call('lrange', queue_key, -1 - offset, 0 - offset)[1]
if pivot then
  redis.call('linsert', queue_key, 'BEFORE', pivot, entry)
else
  redis.call('lpush', queue_key, entry)
end

redis.call('zrem', zset_key, entry)

return true
