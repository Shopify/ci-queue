use clap::ValueEnum;

#[derive(ValueEnum, Clone, Copy, Debug)]
pub enum NodeRunner {
    Pnpm,
    Yarn,
    Npm,
    Npx,
}

const SEARCH_ORDER: &[NodeRunner] = &[NodeRunner::Pnpm, NodeRunner::Yarn, NodeRunner::Npm, NodeRunner::Npx];

impl NodeRunner {
    pub fn command(&self) -> &'static str {
        match self {
            Self::Pnpm => "pnpm",
            Self::Yarn => "yarn",
            Self::Npm => "npm",
            Self::Npx => "npx",
        }
    }
    
    pub fn args(&self) -> Vec<String> {
        match self {
            Self::Pnpm => vec!["exec", "playwright"],
            Self::Yarn => vec!["playwright"],
            Self::Npm => vec!["exec", "--", "playwright"],
            Self::Npx => vec!["playwright"],
        }
        .into_iter()
        .map(String::from)
        .collect()
    }
}

#[derive(Debug, thiserror::Error)]
pub enum NodeRunnerError {
    #[error("No Node.js package manager found (tried: pnpm, yarn, npm, npx)")]
    NoPackageManagerFound,
}

pub fn detect_node_runner() -> Result<NodeRunner, NodeRunnerError> {
    SEARCH_ORDER
        .iter()
        .find(|runner| which::which(runner.command()).is_ok())
        .copied()
        .ok_or(NodeRunnerError::NoPackageManagerFound)
}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_detect_node_runner() {
        let result = detect_node_runner();
        if result.is_ok() {
            let runner = result.unwrap();
            assert!(["pnpm", "yarn", "npm", "npx"].contains(&runner.command()));
        }
    }
}