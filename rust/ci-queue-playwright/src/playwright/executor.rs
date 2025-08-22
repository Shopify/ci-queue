use std::process::{Command, Stdio};
use crate::playwright::types::{PlaywrightTest, PlaywrightListOutput};
use crate::playwright::node_runner::{NodeRunner, NodeRunnerError};
use ci_queue_core::Queue;

#[derive(Debug, thiserror::Error)]
pub enum ExecutorError {
    #[error("Node runner error: {0}")]
    NodeRunner(#[from] NodeRunnerError),
    
    #[error("Failed to execute playwright test --list: {0}")]
    ListCommand(#[from] std::io::Error),
    
    #[error("Failed to list tests: {0}")]
    ListTestsFailed(String),
    
    #[error("Failed to parse Playwright JSON output: {0}")]
    ParseJson(#[from] serde_json::Error),
}

pub fn list_tests(runner: &NodeRunner) -> Result<Vec<PlaywrightTest>, ExecutorError> {
    let cmd: &'static str = runner.command();
    let mut args = runner.args();
    args.extend(["test", "--list", "--reporter=json"].iter().map(|s| s.to_string()));

    let output = Command::new(&cmd)
        .args(&args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(ExecutorError::ListTestsFailed(stderr.to_string()));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    
    let list_output: PlaywrightListOutput = serde_json::from_str(&stdout)?;

    let mut tests = Vec::new();
    for suite in list_output.suites {
        for spec in suite.specs {
            tests.push(PlaywrightTest {
                title: spec.title,
                file: spec.file,
                line: spec.line,
                column: spec.column,
            });
        }
    }

    Ok(tests)
}

pub fn run_test(runner: &NodeRunner, test: &PlaywrightTest) -> Result<bool, ExecutorError> {
    let cmd: &'static str = runner.command();
    let mut args = runner.args();
    
    // TODO: extend with passing through options to the test command
    args.extend(["test", &format!("{}:{}", test.file, test.line.unwrap_or(0))].iter().map(|s| s.to_string()));

    println!("Running: {} ({}:{})", test.title, test.file, test.line.unwrap_or(0));

    let status = Command::new(&cmd)
        .args(&args)
        .status()?;

    Ok(status.success())
}

pub fn process_queue(runner: &NodeRunner, mut queue: Box<dyn Queue<PlaywrightTest>>) -> Result<(), ExecutorError> {
    let mut passed = 0;
    let mut failed = Vec::new();
    let mut test_count = 0;

    while let Some(test) = queue.next() {
        test_count += 1;
        
        println!("\n[{}] ", test_count);

        match run_test(runner, &test) {
            Ok(true) => {
                println!("  ✅ PASSED");
                passed += 1;
            }
            Ok(false) => {
                println!("  ❌ FAILED");
                
                if !queue.requeue(&test) {
                    failed.push(test.clone());
                } else {
                    println!("  🔄 Requeued for retry");
                }
            }
            Err(e) => {
                eprintln!("  ⚠️ Error running test: {}", e);
                failed.push(test.clone());
            }
        }

        queue.acknowledge(&test);
    }

    println!("\n========================================");
    println!("Test Results Summary");
    println!("========================================");
    println!("Total:  {}", test_count);
    println!("Passed: {}", passed);
    println!("Failed: {}", failed.len());

    if !failed.is_empty() {
        println!("\nFailed tests:");
        for test in &failed {
            println!("  - {} ({})", test.title, test.file);
        }
        std::process::exit(1);
    }

    Ok(())
}