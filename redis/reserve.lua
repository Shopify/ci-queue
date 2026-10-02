local queue_key = KEYS[1]
local zset_key = KEYS[2]
local processed_key = KEYS[3]
local worker_queue_key = KEYS[4]
local owners_key = KEYS[5]
local requeued_by_key = KEYS[6]
local workers_key = KEYS[7]
local leases_key = KEYS[8]
local lease_counter_key = KEYS[9]

local current_time = ARGV[1]
local defer_offset = tonumber(ARGV[2]) or 0
local max_skip_attempts = 4

-- Inserts `entry` behind the `offset` + 1 entries nearest the tail, the end RPOP reserves
-- from: where `LINSERT BEFORE <entry at index -(offset + 1)>` would put it. LINSERT finds its
-- pivot by scanning from the head, which is O(queue length) and blocks Redis on large queues;
-- this only touches the tail, so it is O(offset). Queues of at most `offset` + 1 entries, and
-- offsets of zero or less, push to the head instead.
-- Keep in sync with requeue.lua: the Python client does not resolve `-- @include`.
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

local function claim_test(test)
  local lease = redis.call('incr', lease_counter_key)
  redis.call('zadd', zset_key, current_time, test)
  redis.call('lpush', worker_queue_key, test)
  redis.call('hset', owners_key, test, worker_queue_key)
  redis.call('hset', leases_key, test, lease)
  return {test, tostring(lease)}
end

for attempt = 1, max_skip_attempts do
  local test = redis.call('rpop', queue_key)
  if not test then
    return nil
  end

  local requeued_by = redis.call('hget', requeued_by_key, test)
  if requeued_by == worker_queue_key then
    -- If this build only has one worker, allow immediate self-pickup.
    if redis.call('scard', workers_key) <= 1 then
      redis.call('hdel', requeued_by_key, test)
      return claim_test(test)
    end

    insert_with_offset(queue_key, test, defer_offset)

    -- If this worker only finds its own requeued tests, defer once by returning nil,
    -- then allow pickup on a subsequent reserve attempt.
    if attempt == max_skip_attempts then
      redis.call('hdel', requeued_by_key, test)
      return nil
    end
  else
    redis.call('hdel', requeued_by_key, test)
    return claim_test(test)
  end
end

return nil
