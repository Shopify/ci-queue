local zset_key = KEYS[1]
local processed_key = KEYS[2]

local test = ARGV[1]

redis.call('zrem', zset_key, test)
return redis.call('sadd', processed_key, test)
