local processed_key = KEYS[1]
local requeues_count_key = KEYS[2]
local queue_key = KEYS[3]
local zset_key = KEYS[4]
local worker_queue_key = KEYS[5]
local owners_key = KEYS[6]

local max_requeues = tonumber(ARGV[1])
local global_max_requeues = tonumber(ARGV[2])
local test = ARGV[3]
local offset = ARGV[4]

if redis.call('hget', owners_key, test) == worker_queue_key then
   redis.call('hdel', owners_key, test)
end

if redis.call('sismember', processed_key, test) == 1 then
  return false
end

local global_requeues = tonumber(redis.call('hget', requeues_count_key, '___total___'))
if global_requeues and global_requeues >= tonumber(global_max_requeues) then
  return false
end

local requeues = tonumber(redis.call('hget', requeues_count_key, test))
if requeues and requeues >= max_requeues then
  return false
end

redis.call('hincrby', requeues_count_key, '___total___', 1)
redis.call('hincrby', requeues_count_key, test, 1)

local pivot = redis.call('lrange', queue_key, -1 - offset, 0 - offset)[1]
if pivot then
  redis.call('linsert', queue_key, 'BEFORE', pivot, test)
else
  redis.call('lpush', queue_key, test)
end

redis.call('zrem', zset_key, test)

return true
