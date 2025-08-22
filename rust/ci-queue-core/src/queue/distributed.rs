use std::time::{Duration, SystemTime, UNIX_EPOCH};
use redis::{Commands, Connection};

pub mod scripts;
pub mod worker;
pub mod supervisor;

pub use worker::Worker;
pub use supervisor::Supervisor;

const KEY_PREFIX: &str = "build";
const DEFAULT_MASTER_WAIT_TIMEOUT: Duration = Duration::from_secs(10);
const DEFAULT_REQUEUE_OFFSET: i64 = 42;

#[derive(Debug, thiserror::Error)]
#[error("Master worker is {status:?} after {timeout:?} waiting")]
pub struct LostMasterError {
    status: Option<String>,
    timeout: Duration,
}

#[derive(Debug, thiserror::Error)]
#[error("Reservation error: {message}")]
pub struct ReservationError {
    message: String,
}

/// Base functionality shared by Worker and Supervisor
pub struct Base {
    pub redis: Connection,
    pub build_id: String,
    pub is_master: bool,
    pub total: Option<usize>,
    master_wait_timeout: Duration,
}

impl Base {
    pub fn new(redis: Connection, build_id: String) -> Self {
        Self {
            redis,
            build_id,
            is_master: false,
            total: None,
            master_wait_timeout: DEFAULT_MASTER_WAIT_TIMEOUT,
        }
    }

    pub fn set_master_wait_timeout(&mut self, timeout: Duration) {
        self.master_wait_timeout = timeout;
    }

    pub fn key(&self, parts: &[&str]) -> String {
        let mut key_parts = vec![KEY_PREFIX, &self.build_id];
        key_parts.extend_from_slice(parts);
        key_parts.join(":")
    }

    pub fn timestamp() -> f64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs_f64()
    }

    pub fn master_status(&mut self) -> Option<String> {
        self.redis
            .get::<_, Option<String>>(self.key(&["master-status"]))
            .ok()
            .flatten()
    }

    pub fn wait_for_master(&mut self) -> Result<(), LostMasterError> {
        if self.is_master {
            return Ok(());
        }

        let start = SystemTime::now();
        loop {
            match self.master_status() {
                Some(status) if status == "ready" || status == "finished" => return Ok(()),
                status => {
                    let elapsed = SystemTime::now().duration_since(start).unwrap_or_default();
                    if elapsed > self.master_wait_timeout {
                        return Err(LostMasterError {
                            status,
                            timeout: self.master_wait_timeout,
                        });
                    }
                }
            }
            std::thread::sleep(Duration::from_millis(100));
        }
    }

    /// Get queue length (items in queue + items running)
    pub fn len(&mut self) -> usize {
        let queue_len: usize = self.redis
            .llen(self.key(&["queue"]))
            .unwrap_or(0);
        
        let running_len: usize = self.redis
            .zcard(self.key(&["running"]))
            .unwrap_or(0);
        
        queue_len + running_len
    }

    pub fn is_empty(&mut self) -> bool {
        self.len() == 0
    }

    pub fn progress(&mut self) -> usize {
        self.total.unwrap_or(0).saturating_sub(self.len())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_key_generation() {
        // Test the key generation logic directly without Base struct
        let build_id = "test-build-123";
        
        // Replicate the key generation logic
        fn make_key(build_id: &str, parts: &[&str]) -> String {
            let mut key_parts = vec![KEY_PREFIX, build_id];
            key_parts.extend_from_slice(parts);
            key_parts.join(":")
        }
        
        assert_eq!(make_key(build_id, &["queue"]), "build:test-build-123:queue");
        assert_eq!(make_key(build_id, &["worker", "w1", "queue"]), "build:test-build-123:worker:w1:queue");
        assert_eq!(make_key(build_id, &[]), "build:test-build-123");
    }

    #[test]
    fn test_timestamp() {
        let ts1 = Base::timestamp();
        std::thread::sleep(Duration::from_millis(10));
        let ts2 = Base::timestamp();
        
        assert!(ts2 > ts1);
        assert!(ts1 > 0.0);
    }
}