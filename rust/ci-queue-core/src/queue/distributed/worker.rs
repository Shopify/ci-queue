use std::collections::HashSet;
use std::time::Duration;
use redis::Commands;
use super::{Base, ReservationError, DEFAULT_REQUEUE_OFFSET};
use super::scripts::Script;
use crate::queue::{Queue, QueueConfig, TestIdentifier, TestRegistry};
use uuid::Uuid;

/// Distributed worker that processes tests from the Redis queue
pub struct Worker<T: TestIdentifier> {
    base: Base,
    config: QueueConfig,
    worker_id: String,
    shutdown_required: bool,
    reserved_tests: HashSet<T>,
    test_registry: TestRegistry<T>,
}

impl<T: TestIdentifier> Worker<T> {
    pub fn new(
        redis_url: &str,
        build_id: String,
        worker_id: Option<String>,
        tests: Vec<T>,
        config: QueueConfig,
    ) -> Result<Self, redis::RedisError> {
        let client = redis::Client::open(redis_url)?;
        let conn = client.get_connection()?;
        
        let mut base = Base::new(conn, build_id);
        base.total = Some(tests.len());
        
        let mut worker = Self {
            base,
            config,
            worker_id: worker_id.unwrap_or_else(|| Uuid::new_v4().to_string()),
            shutdown_required: false,
            reserved_tests: HashSet::new(),
            test_registry: TestRegistry::new(&tests),
        };
        
        // Attempt to become master and push tests
        worker.push_tests(&tests)?;
        
        Ok(worker)
    }

    pub fn set_master_wait_timeout(&mut self, timeout: Duration) {
        self.base.set_master_wait_timeout(timeout);
    }
    
    pub fn shutdown(&mut self) {
        self.shutdown_required = true;
    }
    
    pub fn is_shutdown_required(&self) -> bool {
        self.shutdown_required
    }
    
    pub fn is_master(&self) -> bool {
        self.base.is_master
    }
    
    /// Push tests to the queue (master election)
    fn push_tests(&mut self, tests: &[T]) -> redis::RedisResult<()> {
        let master_key = self.base.key(&["master-status"]);
        
        // Try to become master using SETNX
        let became_master: bool = self.base.redis.set_nx(&master_key, "setup")?;

        if became_master {
            self.base.is_master = true;
            
            let queue_key = self.base.key(&["queue"]);
            let total_key = self.base.key(&["total"]);
            
            redis::pipe()
                .atomic()
                .lpush(&queue_key, &tests.iter().map(|t| t.to_redis_value()).collect::<Vec<String>>())
                .set(&total_key, tests.len())
                .set(&master_key, "ready")
                .query::<()>(&mut self.base.redis)?;
        }
        
        // Register as a worker
        let workers_key = self.base.key(&["workers"]);
        self.base.redis.sadd::<_, _, ()>(&workers_key, &self.worker_id)?;
        
        Ok(())
    }
    
    /// Reserve a test from the queue
    fn reserve(&mut self) -> Option<T> {
        // First try to get a lost test, then a normal test
        self.try_reserve_lost_test()
            .or_else(|| self.try_reserve_test())
    }
    
    /// Try to reserve a test that was lost (timed out)
    fn try_reserve_lost_test(&mut self) -> Option<T> {
        let keys = vec![
            self.base.key(&["running"]),
            self.base.key(&["completed"]),
            self.base.key(&["worker", &self.worker_id, "queue"]),
            self.base.key(&["owners"]),
        ];
        
        let args = vec![
            Base::timestamp().to_string(),
            self.config.timeout.to_string(),
        ];
        
        match Script::ReserveLost.eval(&mut self.base.redis, keys, args) {
            Ok(redis::Value::BulkString(data)) if !data.is_empty() => {
                String::from_utf8(data)
                    .ok()
                    .and_then(|s| T::from_redis_value(&s, &self.test_registry))            
            }
            _ => None,
        }
    }
    
    /// Try to reserve a normal test from the queue
    fn try_reserve_test(&mut self) -> Option<T> {
        let keys = vec![
            self.base.key(&["queue"]),
            self.base.key(&["running"]),
            self.base.key(&["processed"]),
            self.base.key(&["worker", &self.worker_id, "queue"]),
            self.base.key(&["owners"]),
        ];
        
        let args = vec![Base::timestamp().to_string()];
        
        match Script::Reserve.eval(&mut self.base.redis, keys, args) {
            Ok(redis::Value::BulkString(data)) if !data.is_empty() => {
                String::from_utf8(data)
                    .ok()
                    .and_then(|s| T::from_redis_value(&s, &self.test_registry))
            }
            _ => None,
        }
    }
    
    pub fn acknowledge_test(&mut self, test: &T) -> Result<bool, ReservationError> {
        // Check if we have this test reserved
        if !self.reserved_tests.remove(test) {
            return Err(ReservationError {
                message: format!("Test '{}' was not reserved by this worker", test.to_redis_value()),
            });
        }
        
        let keys = vec![
            self.base.key(&["running"]),
            self.base.key(&["processed"]),
            self.base.key(&["owners"]),
            self.base.key(&["error-reports"]),
        ];
        
        let args = vec![
            test.to_redis_value(),
            String::new(),       // No error
            "28800".to_string(), // TTL: 8 hours
        ];
        
        match Script::Acknowledge.eval(&mut self.base.redis, keys, args) {
            Ok(redis::Value::Int(1)) => Ok(true),
            _ => Ok(false),
        }
    }
    
    /// Requeue a failed test
    pub fn requeue_test(&mut self, test: &T) -> bool {
        let global_max = (self.config.requeue_tolerance * self.base.total.unwrap_or(0) as f64).ceil() as usize;

        if self.config.max_requeues == 0 || global_max == 0 {
            return false;
        }
        
        let keys = vec![
            self.base.key(&["processed"]),
            self.base.key(&["requeues-count"]),
            self.base.key(&["queue"]),
            self.base.key(&["running"]),
            self.base.key(&["worker", &self.worker_id, "queue"]),
            self.base.key(&["owners"]),
            self.base.key(&["error-reports"]),
        ];
        
        let args = vec![
            self.config.max_requeues.to_string(),
            global_max.to_string(),
            test.to_redis_value(),
            DEFAULT_REQUEUE_OFFSET.to_string(),
        ];
        
        match Script::Requeue.eval(&mut self.base.redis, keys, args) {
            Ok(redis::Value::Int(1)) => {
                self.reserved_tests.remove(test);
                true
            }
            _ => false,
        }
    }
}

impl<T: TestIdentifier> Queue<T> for Worker<T> {
    fn total(&self) -> usize {
        self.base.total.unwrap_or(0)
    }
    
    fn progress(&mut self) -> usize {
        self.base.progress()
    }
    
    fn len(&mut self) -> usize {
        self.base.len()
    }
    
    fn acknowledge(&mut self, test: &T) -> bool {
        self.acknowledge_test(test).unwrap_or(false)
    }
    
    fn requeue(&mut self, test: &T) -> bool {
        self.requeue_test(test)
    }
}

impl<T: TestIdentifier> Iterator for Worker<T> {
    type Item = T;
    
    fn next(&mut self) -> Option<Self::Item> {
        if self.base.wait_for_master().is_err() {
            return None;
        }
        
        if self.shutdown_required || self.base.is_empty() {
            return None;
        }
        
        if let Some(test) = self.reserve() {
            self.reserved_tests.insert(test.clone());
            Some(test)
        } else {
            std::thread::sleep(Duration::from_millis(50));
            self.next()
        }
    }
}