use std::{collections::HashMap, hash::Hash};

pub mod static_queue;
pub mod distributed;

/// Configuration for queue behavior
#[derive(Debug, Clone)]
pub struct QueueConfig {
    pub max_requeues: usize,
    pub requeue_tolerance: f64,
    pub timeout: usize,
}

impl Default for QueueConfig {
    fn default() -> Self {
        Self {
            max_requeues: 0,
            requeue_tolerance: 0.0,
            timeout: 60,
        }
    }
}

/// Result of a test execution
#[derive(Debug, Clone, PartialEq)]
pub enum TestResult {
    Passed,
    Failed,
    Skipped,
}

pub trait TestIdentifier: Clone + Hash + Eq {
    fn to_redis_value(&self) -> String;
    fn from_redis_value(s: &str, registry: &TestRegistry<Self>) -> Option<Self>;
}

// Default implementation for String - unnecessary to use registry
impl TestIdentifier for String {
    fn to_redis_value(&self) -> String {
        self.clone()
    }

    fn from_redis_value(s: &str, _registry: &TestRegistry<Self>) -> Option<Self> {
        Some(s.to_string())
    }
}

#[derive(Debug)]
pub struct TestRegistry<T: TestIdentifier> {
    tests: HashMap<String, T>,
}

impl<T: TestIdentifier> TestRegistry<T> {
    pub fn new(tests: &[T]) -> Self {
        Self {
            tests: tests.into_iter().map(|t| (t.to_redis_value(), t.clone())).collect(),
        }
    }

    pub fn get(&self, s: &str) -> Option<&T> {
        self.tests.get(s)
    }
}

pub trait Queue<T: TestIdentifier>: Iterator<Item = T> {
    /// Get the total number of tests
    fn total(&self) -> usize;

    /// Get the current progress
    fn progress(&mut self) -> usize;

    /// Get the remaining tests count
    fn len(&mut self) -> usize;

    /// Check if the queue is empty
    fn is_empty(&mut self) -> bool {
        self.len() == 0
    }

    /// Acknowledge a test as completed
    fn acknowledge(&mut self, test: &T) -> bool;

    /// Requeue a failed test
    fn requeue(&mut self, test: &T) -> bool;
}