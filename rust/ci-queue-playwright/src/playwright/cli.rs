use clap::{Parser, Subcommand};

use crate::playwright::node_runner;

#[derive(Parser, Debug)]
#[command(version)]
#[command(name = "playwright-queue")]
#[command(about = "Distributed Playwright test runner using ci-queue")]
#[command(flatten_help = true)]
pub struct Args {
    #[command(subcommand)]
    pub command: Commands,

    #[arg(long, env = "BUILD_ID", help = "Unique identifier for the workload. All workers working on the same suite of tests must have the same build identifier")]
    pub build: String,

    // TODO: Implement from minitest-queue
    // #[arg(long, help = "Count defines how often each test in the grind list is going to be run")]
    // grind_count: Option<usize>,

    // TODO: Implement from minitest-queue
    // #[arg(long, help = "Path to the file that includes the list of tests to grind")]
    // grind_list: Option<String>,

    // TODO: Implement from minitest-queue
    // #[arg(long, help = "Optional. Sets a prefix for the build id in case a single CI build runs multiple independent test suites")]
    // namespace: Option<String>,

    #[arg(long, env = "QUEUE_URL", help = "URL of the queue, e.g. redis://example.com")]
    pub queue: String,

    #[arg(long, value_enum, env = "NODE_RUNNER", help = "Node runner to use for executing tests")]
    pub runner: Option<node_runner::NodeRunner>,
}

#[derive(Subcommand, Debug)]
pub enum Commands {    
    Run {
        // TODO: Implement from minitest-queue
        // #[arg(long, help = "Path to debug log file for e.g. Redis instrumentation")]
        // debug_log: Option<String>,

        // TODO: Implement from minitest-queue
        // #[arg(long, help = "Defines a file where flaky tests during the execution are written to in json format")]
        // export_flaky_tests_file: Option<String>,

        // TODO: Implement from minitest-queue
        // #[arg(long, help = "Defines a file where the test failures are written to in the json format")]
        // failure_file: Option<String>,

        // TODO: Implement from minitest-queue
        // #[arg(long, help = "If heartbeat is enabled, a background process will periodically signal it's still processing the current test (in seconds)")]
        // heartbeat: Option<usize>,

        // TODO: Implement from minitest-queue
        // #[arg(long, default_value = "30", help = "Specify a timeout after which all workers are inactive (e.g. died) (in seconds)")]
        // inactive_workers_timeout: usize,

        // TODO: Implement from minitest-queue
        // #[arg(long, help = "Defines after how many consecutive failures the worker will be considered unhealthy and terminate itself")]
        // max_consecutive_failures: Option<usize>,

        // TODO: Implement from minitest-queue
        // #[arg(long, help = "Defines how long ci-queue should maximally run in seconds")]
        // max_duration: Option<usize>,

        #[arg(long, default_value = "0", help = "Defines how many times a single test can be requeued")]
        max_requeues: usize,

        // TODO: Implement from minitest-queue
        // #[arg(long, help = "Defines how many user test tests can fail")]
        // max_test_failed: Option<usize>,

        // TODO: Implement from minitest-queue
        // #[arg(long, help = "Set the time limit of the execution time from grinds on a given test (in milliseconds, decimal allowed)")]
        // max_test_duration: Option<f64>,

        // TODO: Implement from minitest-queue
        // #[arg(long, default_value = "0.5", help = "The percentile for max-test-duration. Must be within the range 0 < percentile <= 1")]
        // max_test_duration_percentile: f64,

        // TODO: Implement from minitest-queue
        // #[arg(long, default_value = "30", help = "Specify a timeout to elect the leader and populate the queue (in seconds)")]
        // queue_init_timeout: usize,

        // TODO: Implement from minitest-queue
        // #[arg(long, default_value = "28800", help = "Defines how long the test report remain after the test run, in seconds. Defaults to 28,800 (8 hours)")]
        // redis_ttl: usize,

        // TODO: Implement from minitest-queue
        // #[arg(long, default_value = "30", help = "Specify a timeout after which the report command will fail if not all tests have been processed (in seconds)")]
        // report_timeout: usize,

        #[arg(long, default_value = "0.0", help = "Defines how many requeues can happen overall, based on the test suite size (e.g. 0.05 for 5%)")]
        requeue_tolerance: f64,

        #[arg(long, help = "Specify a seed used to shuffle the test suite. If not provided, the tests will be run in the default order provided by `playwright test --list`.")]
        seed: Option<String>,

        #[arg(long, default_value = "60", help = "Timeout after which if a test hasn't completed, it will be picked up by another worker (in seconds)")]
        timeout: usize,

        // TODO: Implement from minitest-queue
        // #[arg(long, help = "Must set this option in report and report_grind command if you set --max-test-duration in the report_grind")]
        // track_test_duration: bool,

        // TODO: Implement from minitest-queue
        // #[arg(short, long, help = "Verbose. Show progress processing files")]
        // verbose: bool,

        // TODO: Implement from minitest-queue
        // #[arg(long, help = "Defines a file where warnings during the execution are written to")]
        // warnings_file: Option<String>,

        #[arg(long, env = "WORKER_ID", help = "A unique identifier for this worker. Must be consistent to allow retries")]
        worker: Option<String>,
    },
    
    // TODO: Implement from minitest-queue
    // Report {
    //     #[arg(long, default_value = "30", help = "Specify a timeout after which all workers are inactive (e.g. died) (in seconds)")]
    //     inactive_workers_timeout: usize,

    //     #[arg(long, default_value = "30", help = "Specify a timeout after which the report command will fail if not all tests have been processed (in seconds)")]
    //     report_timeout: usize,

    //     #[arg(long, help = "Must set this option in report and report_grind command if you set --max-test-duration in the report_grind")]
    //     track_test_duration: bool,

    //     #[arg(short, long, help = "Verbose. Show progress processing files")]
    //     verbose: bool,
    // }

    // TODO: Implement from minitest-queue
    // Retry {}

    // TODO: Implement from minitest-queue
    // Bisect {
    //     #[arg(long)]
    //     failing_test: String,
    // }
}
