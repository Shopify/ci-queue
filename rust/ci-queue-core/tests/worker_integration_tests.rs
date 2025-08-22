mod utils;

use ci_queue_core::queue::distributed::Worker;
use ci_queue_core::queue::{Queue, QueueConfig};
use std::time::Duration;

#[test]
#[ignore]
fn test_single_worker_processes_all_tests() {
    redis_test!(ctx, {
        let tests = vec![
            "test::module1::test_a".to_string(),
            "test::module1::test_b".to_string(),
            "test::module2::test_c".to_string(),
        ];
        
        let mut worker = Worker::new(
            "redis://127.0.0.1/",
            ctx.build_id.clone(),
            Some("worker-1".to_string()),
            tests.clone(),
            QueueConfig::default(),
        ).expect("Failed to create worker");
        
        assert!(worker.is_master());
        assert_eq!(worker.total(), 3);
        
        let mut processed = Vec::new();
        while let Some(test) = worker.next() {
            processed.push(test.clone());
            assert!(worker.acknowledge(&test));
        }
        
        assert_eq!(processed.len(), 3);
        
        let progress = worker.progress();
        assert_eq!(progress, 3);
        
        let remaining = worker.len();
        assert_eq!(remaining, 0);
    });
}

#[test]
#[ignore]
fn test_multiple_workers_share_queue() {
    redis_test!(ctx, {
        let tests = vec![
            "test1".to_string(),
            "test2".to_string(),
            "test3".to_string(),
            "test4".to_string(),
            "test5".to_string(),
            "test6".to_string(),
        ];
        
        let mut worker1 = Worker::new(
            "redis://127.0.0.1/",
            ctx.build_id.clone(),
            Some("worker-1".to_string()),
            tests.clone(),
            QueueConfig::default(),
        ).expect("Failed to create worker1");
        
        let mut worker2 = Worker::new(
            "redis://127.0.0.1/",
            ctx.build_id.clone(),
            Some("worker-2".to_string()),
            tests.clone(),
            QueueConfig::default(),
        ).expect("Failed to create worker2");
        
        assert!(worker1.is_master() != worker2.is_master());
        
        let mut all_processed = Vec::new();
        
        for _ in 0..3 {
            if let Some(test) = worker1.next() {
                all_processed.push(test.clone());
                assert!(worker1.acknowledge(&test));
            }
            
            if let Some(test) = worker2.next() {
                all_processed.push(test.clone());
                assert!(worker2.acknowledge(&test));
            }
        }
        
        assert_eq!(all_processed.len(), 6);
        
        let unique_tests: std::collections::HashSet<_> = all_processed.iter().collect();
        assert_eq!(unique_tests.len(), 6);
    });   
}

#[test]
#[ignore]
fn test_worker_requeue_failed_test() {
    redis_test!(ctx, {
        let tests = vec![
            "test1".to_string(),
            "test2".to_string(),
        ];
        
        let config = QueueConfig {
            max_requeues: 2,
            requeue_tolerance: 1.0,
            timeout: 60,
        };
        
        let mut worker = Worker::new(
            "redis://127.0.0.1/",
            ctx.build_id.clone(),
            Some("worker-1".to_string()),
            tests.clone(),
            config,
        ).expect("Failed to create worker");
        
        let test1 = worker.next().expect("Should get test1");
        assert_eq!(test1, "test1");
        
        assert!(worker.requeue(&test1));
        
        let test2 = worker.next().expect("Should get test2");
        assert_eq!(test2, "test2");
        assert!(worker.acknowledge(&test2));
        
        let requeued_test = worker.next().expect("Should get requeued test1");
        assert_eq!(requeued_test, "test1");
        assert!(worker.acknowledge(&requeued_test));
        
        assert_eq!(worker.next(), None);
    });
}

#[test]
#[ignore]
fn test_worker_timeout_and_recovery() {
    redis_test!(ctx, {
        let tests = vec!["test1".to_string(), "test2".to_string()];

        let config = QueueConfig {
            max_requeues: 2,
            requeue_tolerance: 1.0,
            timeout: 1,
        };
        
        let mut worker1 = Worker::new(
            "redis://127.0.0.1/",
            ctx.build_id.clone(),
            Some("worker-1".to_string()),
            tests.clone(),
            config.clone(),
        ).expect("Failed to create worker1");
        
        
        let test1 = worker1.next().expect("Should get test1");
        
        std::thread::sleep(Duration::from_secs(2));
        
        let mut worker2 = Worker::new(
            "redis://127.0.0.1/",
            ctx.build_id.clone(),
            Some("worker-2".to_string()),
            tests.clone(),
            config.clone(),
        ).expect("Failed to create worker2");
        
        let recovered_test = worker2.next();
        assert!(recovered_test.is_some());
        
        if let Some(test) = recovered_test {
            assert_eq!(test, test1);
            assert!(worker2.acknowledge(&test));
        }
    });
}

#[test]
#[ignore]
fn test_worker_shutdown() {
    redis_test!(ctx, {
        let tests = vec![
            "test1".to_string(),
            "test2".to_string(),
            "test3".to_string(),
        ];
        
        let mut worker = Worker::new(
            "redis://127.0.0.1/",
            ctx.build_id.clone(),
            Some("worker-1".to_string()),
            tests.clone(),
            QueueConfig::default(),
        ).expect("Failed to create worker");
        
        let test1 = worker.next().expect("Should get test1");
        assert!(worker.acknowledge(&test1));
        
        worker.shutdown();
        assert!(worker.is_shutdown_required());
        
        assert_eq!(worker.next(), None);
    });
}

#[test]
#[ignore]
fn test_max_requeues_limit() {
    redis_test!(ctx, {
        // Use 2 tests so that with tolerance 1.0, we get global_max = 2
        // This allows us to test that per-test limit (max_requeues=2) is enforced
        let tests = vec!["test1".to_string(), "test2".to_string()];
        
        let config = QueueConfig {
            max_requeues: 2,
            requeue_tolerance: 1.0,  // With 2 tests, global_max = ceil(1.0 * 2) = 2
            timeout: 60,
        };
        
        let mut worker = Worker::new(
            "redis://127.0.0.1/",
            ctx.build_id.clone(),
            Some("worker-1".to_string()),
            tests.clone(),
            config,
        ).expect("Failed to create worker");
        
        // Get test1 first
        let test1 = worker.next().expect("Should get test1");
        assert_eq!(test1, "test1");
        
        // First requeue of test1 should succeed
        assert!(worker.requeue(&test1), "First requeue of test1 should succeed");
        
        // Get test2 
        let test2 = worker.next().expect("Should get test2");
        assert_eq!(test2, "test2");
        // Just acknowledge test2 to move on
        assert!(worker.acknowledge(&test2));
        
        // Get test1 again (it was requeued)
        let test1_again = worker.next().expect("Should get test1 again");
        assert_eq!(test1_again, "test1");
        
        // Second requeue of test1 should succeed (still under max_requeues=2)
        assert!(worker.requeue(&test1_again), "Second requeue of test1 should succeed");
        
        // Get test1 for the third time
        let test1_third = worker.next().expect("Should get test1 for third time");
        assert_eq!(test1_third, "test1");
        
        // Third requeue attempt should fail (exceeds max_requeues=2)
        assert!(!worker.requeue(&test1_third), "Third requeue should fail (exceeded max)");
        
        // Must acknowledge it now
        assert!(worker.acknowledge(&test1_third));
    });
}

#[test]
#[ignore]
fn test_lost_master_timeout() {
    redis_test!(ctx, {
        let tests = vec!["test1".to_string(), "test2".to_string()];
        
        // Create master worker
        let master = Worker::new(
            "redis://127.0.0.1/",
            ctx.build_id.clone(),
            Some("master".to_string()),
            tests.clone(),
            QueueConfig::default(),
        ).expect("Failed to create master");
        
        assert!(master.is_master());
        
        // Set master status to something other than "ready" or "finished"
        // This simulates a stuck or crashed master
        let client = redis::Client::open("redis://127.0.0.1/").unwrap();
        let mut con = client.get_connection().unwrap();
        let master_key = format!("build:{}:master-status", ctx.build_id);
        
        let _: () = redis::cmd("SET")
            .arg(&master_key)
            .arg("stuck")
            .query(&mut con)
            .unwrap();

       // Create another worker and expect it to timeout after the master wait timeout
       let mut worker = Worker::new(
        "redis://127.0.0.1/",
        ctx.build_id.clone(),
        Some("worker-1".to_string()),
        tests.clone(),
        QueueConfig::default(),
       ).expect("Failed to create worker");
       worker.set_master_wait_timeout(Duration::from_millis(50));

       // Expect the worker to timeout - it should not be able to get a test
       assert!(worker.next().is_none());
    });
}