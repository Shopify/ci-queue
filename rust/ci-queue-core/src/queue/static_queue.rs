use std::collections::{HashMap, VecDeque};
use crate::queue::TestIdentifier;

use super::{Queue, QueueConfig};

/// Static queue implementation - holds tests in memory
pub struct StaticQueue<T: TestIdentifier> {
    queue: VecDeque<T>,
    progress: usize,
    total: usize,
    config: QueueConfig,
    requeues: HashMap<T, usize>,
    global_requeue_count: usize,
}

impl<T: TestIdentifier> StaticQueue<T> {
    /// Create a new static queue with the given tests
    pub fn new(tests: Vec<T>, config: QueueConfig) -> Self {
        let total = tests.len();
        Self {
            queue: tests.into_iter().collect(),
            progress: 0,
            total,
            config,
            requeues: HashMap::new(),
            global_requeue_count: 0,
        }
    }

    /// Calculate the maximum global requeues allowed
    fn global_max_requeues(&self) -> usize {
        (self.config.requeue_tolerance * self.total as f64).ceil() as usize
    }

    /// Check if a test can be requeued
    fn should_requeue(&self, test: &T) -> bool {
        // Check if we've disabled requeues entirely
        if self.config.max_requeues == 0 || self.global_max_requeues() == 0 {
            return false;
        }
        
        let test_requeues = self.requeues.get(test).copied().unwrap_or(0);
        test_requeues < self.config.max_requeues 
            && self.global_requeue_count < self.global_max_requeues()
    }
}

impl<T: TestIdentifier> Queue<T> for StaticQueue<T> {
    fn total(&self) -> usize {
        self.total
    }

    fn progress(&mut self) -> usize {
        self.progress
    }

    fn len(&mut self) -> usize {
        self.queue.len()
    }

    fn acknowledge(&mut self, _test: &T) -> bool {
        // In static queue, acknowledge always succeeds
        true
    }

    fn requeue(&mut self, test: &T) -> bool {
        if !self.should_requeue(test) {
            return false;
        }

        *self.requeues.entry(test.clone()).or_insert(0) += 1;
        self.global_requeue_count += 1;
        
        // Insert at the front of the queue (like Python implementation)
        self.queue.push_front(test.clone());
        true
    }
}

impl<T: TestIdentifier> Iterator for StaticQueue<T> {
    type Item = T;

    fn next(&mut self) -> Option<Self::Item> {
        if let Some(test) = self.queue.pop_front() {
            self.progress += 1;
            Some(test)
        } else {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_basic_queue_iteration() {
        let tests = vec!["test1".to_string(), "test2".to_string(), "test3".to_string()];
        let mut queue = StaticQueue::new(tests.clone(), QueueConfig::default());
        
        assert_eq!(queue.total(), 3);
        assert_eq!(queue.len(), 3);
        assert_eq!(queue.progress(), 0);
        
        assert_eq!(queue.next(), Some("test1".to_string()));
        assert_eq!(queue.progress(), 1);
        assert_eq!(queue.len(), 2);
        
        assert_eq!(queue.next(), Some("test2".to_string()));
        assert_eq!(queue.next(), Some("test3".to_string()));
        assert_eq!(queue.next(), None);
        
        assert_eq!(queue.progress(), 3);
        assert_eq!(queue.len(), 0);
    }

    #[test]
    fn test_requeue_respects_max_per_test() {
        let config = QueueConfig {
            max_requeues: 2,
            requeue_tolerance: 3.0, // Allow 300% to be requeued (3 requeues for 1 test)
            timeout: 60,
        };
        let tests = vec!["test1".to_string()];
        let mut queue = StaticQueue::new(tests, config);
        
        // First run
        let test = queue.next().unwrap();
        assert_eq!(test, "test1");
        
        // First requeue - should succeed
        assert!(queue.requeue(&test), "First requeue should succeed");
        assert_eq!(queue.len(), 1);
        assert_eq!(queue.requeues.get("test1").copied().unwrap_or(0), 1);
        
        // Run again
        let test = queue.next().unwrap();
        assert_eq!(test, "test1");
        
        // Second requeue - should succeed (at limit)
        assert!(queue.requeue(&test), "Second requeue should succeed (at limit)");
        assert_eq!(queue.requeues.get("test1").copied().unwrap_or(0), 2);
        
        // Run again
        let test = queue.next().unwrap();
        
        // Third requeue - should fail (exceeds max_requeues of 2)
        assert!(!queue.requeue(&test), "Third requeue should fail");
        assert_eq!(queue.len(), 0);
    }

    #[test]
    fn test_requeue_respects_global_tolerance() {
        let config = QueueConfig {
            max_requeues: 10, // High per-test limit
            requeue_tolerance: 0.5, // Only 50% of tests can be requeued
            timeout: 60,
        };
        let tests = vec!["test1".to_string(), "test2".to_string()];
        let mut queue = StaticQueue::new(tests, config);
        
        // With 2 tests and 0.5 tolerance, only 1 requeue total is allowed
        // (0.5 * 2 = 1.0, ceil(1.0) = 1)
        
        // Run first test
        let test1 = queue.next().unwrap();
        assert!(queue.requeue(&test1));
        
        // Run second test
        let test2 = queue.next().unwrap();
        // This should fail because we've hit global limit
        assert!(!queue.requeue(&test2));
    }

    #[test]
    fn test_requeue_inserts_at_front() {
        let config = QueueConfig {
            max_requeues: 1,
            requeue_tolerance: 1.0,
            timeout: 60,
        };
        let tests = vec!["test1".to_string(), "test2".to_string(), "test3".to_string()];
        let mut queue = StaticQueue::new(tests, config);
        
        // Get first test
        let test1 = queue.next().unwrap();
        assert_eq!(test1, "test1");
        
        // Requeue it
        assert!(queue.requeue(&test1));
        
        // Next should be the requeued test (inserted at front)
        assert_eq!(queue.next().unwrap(), "test1");
        // Then continue with original order
        assert_eq!(queue.next().unwrap(), "test2");
        assert_eq!(queue.next().unwrap(), "test3");
    }

    #[test]
    fn test_zero_requeue_config() {
        let config = QueueConfig {
            max_requeues: 0,
            requeue_tolerance: 0.0,
            timeout: 60,
        };
        let tests = vec!["test1".to_string()];
        let mut queue = StaticQueue::new(tests, config);
        
        let test = queue.next().unwrap();
        // Should not allow any requeues
        assert!(!queue.requeue(&test));
    }

    #[test]
    fn test_requeue_tolerance_ceiling() {
        // Test that requeue tolerance is ceiling'd, not floored
        let config = QueueConfig {
            max_requeues: 10,
            requeue_tolerance: 0.15, // 15% of 3 = 0.45
            timeout: 60,
        };
        let tests = vec!["test1".to_string(), "test2".to_string(), "test3".to_string()];
        let mut queue = StaticQueue::new(tests, config);
        
        // ceil(0.45) = 1, so one requeue should be allowed
        let test1 = queue.next().unwrap();
        assert!(queue.requeue(&test1));
        
        // Second requeue should fail
        let test2 = queue.next().unwrap();
        assert!(!queue.requeue(&test2));
    }
}