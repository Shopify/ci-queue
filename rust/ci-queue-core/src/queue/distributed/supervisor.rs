use std::time::Duration;

use super::{Base};

/// Supervisor monitors the queue and waits for all workers to complete
pub struct Supervisor {
    base: Base,
}

impl Supervisor {
    pub fn new(redis_url: &str, build_id: String) -> Result<Self, redis::RedisError> {
        let client = redis::Client::open(redis_url)?;
        let conn = client.get_connection()?;
        let base = Base::new(conn, build_id);
        
        Ok(Self { base })
    }
    
    pub fn wait_for_workers(&mut self) -> bool {
        if self.base.wait_for_master().is_err() {
            return false;
        }
        
        while !self.base.is_empty() {
            std::thread::sleep(Duration::from_millis(100));
        }
        
        true
    }
    
    pub fn len(&mut self) -> usize {
        self.base.len()
    }
    
    pub fn is_empty(&mut self) -> bool {
        self.base.is_empty()
    }
    
    pub fn progress(&mut self) -> usize {
        self.base.progress()
    }
}