local processed_key = KEYS[1]
local requeues_count_key = KEYS[2]
local queue_key = KEYS[3]
local zset_key = KEYS[4]
local worker_queue_key = KEYS[5]
local owners_key = KEYS[6]
local error_reports_key = KEYS[7]

local max_requeues = tonumber(ARGV[1])
local global_max_requeues = tonumber(ARGV[2])
local queue_entry = ARGV[3]
local offset = ARGV[4]

-- Queue entries may be "file_path\ttest_id" (streaming mode) or plain "test_id".
-- Extract the plain test_id for processed/requeues-count/error-reports keys,
-- but use the full queue_entry for running/owners/queue.
local test_id = queue_entry
local tab_pos = string.find(queue_entry, "\t")
if tab_pos then
  test_id = string.sub(queue_entry, tab_pos + 1)
end

if redis.call('hget', owners_key, queue_entry) == worker_queue_key then
   redis.call('hdel', owners_key, queue_entry)
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
  redis.call('linsert', queue_key, 'BEFORE', pivot, queue_entry)
else
  redis.call('lpush', queue_key, queue_entry)
end

redis.call('zrem', zset_key, queue_entry)

return true
