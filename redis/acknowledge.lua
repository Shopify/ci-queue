local zset_key = KEYS[1]
local processed_key = KEYS[2]
local owners_key = KEYS[3]

local test = ARGV[1]

redis.call('zrem', zset_key, test)
redis.call('hdel', owners_key, test)  -- Doesn't matter if it was reclaimed by another workers
return redis.call('sadd', processed_key, test)
