use clap::Parser;
use ci_queue_core::{QueueConfig, Worker};
use ci_queue_playwright::playwright::{
    cli::{Args, Commands}, list_tests, node_runner, process_queue
};
use rand::{SeedableRng, seq::SliceRandom};
use rand::rngs::StdRng;

#[derive(Debug, thiserror::Error)]
enum AppError {
    #[error("Executor error: {0}")]
    Executor(#[from] ci_queue_playwright::playwright::executor::ExecutorError),
    
    #[error("Worker initialization failed: {0}")]
    WorkerInit(String),

    #[error("Node runner error: {0}")]
    NodeRunner(#[from] node_runner::NodeRunnerError),
}

fn main() -> Result<(), AppError> {
    let args = Args::parse();
    
    match args.command {
        Commands::Run { max_requeues, requeue_tolerance, seed, timeout, worker } => {
            let runner = args.runner.unwrap_or(node_runner::detect_node_runner()?);
            
            let config = QueueConfig {
                max_requeues,
                requeue_tolerance,
                timeout,
            };

            let mut tests = list_tests(&runner)?;
            
            // Randomize tests based on seed if provided
            if let Some(seed_str) = seed {
                let mut rng = StdRng::from_seed(string_to_seed(&seed_str));
                tests.shuffle(&mut rng);
            }

            println!("Running {} tests", tests.len());

            let worker = Worker::new(&args.queue, args.build.clone(), worker, tests, config)
                .map_err(|e| AppError::WorkerInit(e.to_string()))?;

            process_queue(&runner, Box::new(worker))?;
        }
    }

    Ok(())
}

fn string_to_seed(seed_str: &str) -> [u8; 32] {
    let mut seed_bytes = [0u8; 32];
    let seed_hash = seed_str.as_bytes();
    for (i, &byte) in seed_hash.iter().enumerate().take(32) {
        seed_bytes[i] = byte;
    }
    seed_bytes
}