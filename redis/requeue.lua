local processed_key = KEYS[1]
local requeues_count_key = KEYS[2]
local queue_key = KEYS[3]
local zset_key = KEYS[4]
local worker_queue_key = KEYS[5]
local owners_key = KEYS[6]
local error_reports_key = KEYS[7]
local requeued_by_key = KEYS[8]
local leases_key = KEYS[9]

local max_requeues = tonumber(ARGV[1])
local global_max_requeues = tonumber(ARGV[2])
local entry = ARGV[3]
local offset = tonumber(ARGV[4]) or 0
local ttl = tonumber(ARGV[5])
local lease_id = ARGV[6]

-- Inserts `entry` behind the `offset` + 1 entries nearest the tail, the end RPOP reserves
-- from: where `LINSERT BEFORE <entry at index -(offset + 1)>` would put it. LINSERT finds its
-- pivot by scanning from the head, which is O(queue length) and blocks Redis on large queues;
-- this only touches the tail, so it is O(offset). Queues of at most `offset` + 1 entries, and
-- offsets of zero or less, push to the head instead.
-- Keep in sync with reserve.lua: the Python client does not resolve `-- @include`.
local function insert_with_offset(queue_key, entry, offset)
  if offset <= 0 or redis.call('llen', queue_key) <= offset + 1 then
    redis.call('lpush', queue_key, entry)
    return
  end

  local ahead = redis.call('lrange', queue_key, -1 - offset, -1)
  redis.call('ltrim', queue_key, 0, -2 - offset)
  redis.call('rpush', queue_key, entry)
  for _, ahead_entry in ipairs(ahead) do
    redis.call('rpush', queue_key, ahead_entry)
  end
end

-- Only the current lease holder can requeue a test.
-- If the lease was transferred (e.g. via reserve_lost), reject the stale
-- worker's requeue so the running entry stays intact for the new holder.
if tostring(redis.call('hget', leases_key, entry)) ~= lease_id then
  return false
end

if redis.call('sismember', processed_key, entry) == 1 then
  return false
end

local global_requeues = tonumber(redis.call('hget', requeues_count_key, '___total___'))
if global_requeues and global_requeues >= tonumber(global_max_requeues) then
  return false
end

local requeues = tonumber(redis.call('hget', requeues_count_key, entry))
if requeues and requeues >= max_requeues then
  return false
end

redis.call('hincrby', requeues_count_key, '___total___', 1)
redis.call('hincrby', requeues_count_key, entry, 1)

redis.call('hdel', error_reports_key, entry)

insert_with_offset(queue_key, entry, offset)

redis.call('hset', requeued_by_key, entry, worker_queue_key)
if ttl and ttl > 0 then
  redis.call('expire', requeued_by_key, ttl)
end

redis.call('hdel', owners_key, entry)
redis.call('hdel', leases_key, entry)
redis.call('zrem', zset_key, entry)

return true
