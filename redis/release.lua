local zset_key = KEYS[1]
local worker_queue_key = KEYS[2]
local owners_key = KEYS[3]

-- owned_tests = {"SomeTest", "worker:1", "SomeOtherTest", "worker:2", ...}
local owned_tests = redis.call('hgetall', owners_key)
for index, owner_or_test in ipairs(owned_tests) do
  if owner_or_test == worker_queue_key then -- If we owned a test
    local test = owned_tests[index - 1]
    redis.call('zadd', zset_key, "0", test) -- We expire the lease immediately
    return nil
  end
end

return nil
