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

local function insert_with_offset(test)
  local pivot = redis.call('lrange', queue_key, -1 - defer_offset, 0 - defer_offset)[1]
  if pivot then
    redis.call('linsert', queue_key, 'BEFORE', pivot, test)
  else
    redis.call('lpush', queue_key, test)
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

    insert_with_offset(test)

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
