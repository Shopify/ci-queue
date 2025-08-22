pub enum Script {
    Reserve,
    ReserveLost,
    Acknowledge,
    Requeue,
    Release,
    Heartbeat,
}

impl Script {
    pub fn name(&self) -> &'static str {
        match self {
            Script::Reserve => "reserve",
            Script::ReserveLost => "reserve_lost",
            Script::Acknowledge => "acknowledge",
            Script::Requeue => "requeue",
            Script::Release => "release",
            Script::Heartbeat => "heartbeat",
        }
    }

    pub fn content(&self) -> &'static str {
        match self {
            Script::Reserve => include_str!("../../../../../redis/reserve.lua"),
            Script::ReserveLost => include_str!("../../../../../redis/reserve_lost.lua"),
            Script::Acknowledge => include_str!("../../../../../redis/acknowledge.lua"),
            Script::Requeue => include_str!("../../../../../redis/requeue.lua"),
            Script::Release => include_str!("../../../../../redis/release.lua"),
            Script::Heartbeat => include_str!("../../../../../redis/heartbeat.lua"),
        }
    }

    pub fn eval(&self, redis: &mut redis::Connection, keys: Vec<String>, args: Vec<String>) -> redis::RedisResult<redis::Value> {
        let script = redis::Script::new(self.content());
        script.key(keys)
            .arg(args)
            .invoke(redis)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_scripts_load() {
        // Ensure all scripts are loaded correctly
        assert!(!Script::Reserve.content().is_empty());
        assert!(!Script::ReserveLost.content().is_empty());
        assert!(!Script::Acknowledge.content().is_empty());
        assert!(!Script::Requeue.content().is_empty());
        assert!(!Script::Release.content().is_empty());
        assert!(!Script::Heartbeat.content().is_empty());
        
        // Check that scripts contain expected Redis commands
        assert!(Script::Reserve.content().contains("rpop"));
        assert!(Script::ReserveLost.content().contains("zrangebyscore"));
        assert!(Script::Acknowledge.content().contains("zrem"));
        assert!(Script::Requeue.content().contains("linsert"));
    }
}