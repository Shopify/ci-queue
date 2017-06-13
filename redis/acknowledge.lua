local zset_key = KEYS[1]
local processed_key = KEYS[2]

local worker_id = ARGV[1]
local test = ARGV[2]

redis.call('zrem', zset_key, test)
return redis.call('sadd', processed_key, test)
