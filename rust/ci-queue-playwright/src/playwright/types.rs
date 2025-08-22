use ci_queue_core::queue::{TestIdentifier, TestRegistry};
use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize, Serialize, Clone, Hash, PartialEq, Eq)]
pub struct PlaywrightTest {
    pub title: String,
    pub file: String,
    pub line: Option<u32>,
    pub column: Option<u32>,
}

impl TestIdentifier for PlaywrightTest {
    fn to_redis_value(&self) -> String {
        format!("{}:{}:{}", self.file, self.line.unwrap_or(0), self.title)
    }

    fn from_redis_value(s: &str, registry: &TestRegistry<Self>) -> Option<Self> {
        registry.get(s).cloned()
    }
}

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct PlaywrightListOutput {
    #[serde(default)]
    pub config: serde_json::Value,
    #[serde(default)]
    pub errors: Vec<serde_json::Value>,
    #[serde(default)]
    pub suites: Vec<PlaywrightSuite>,
    #[serde(default)]
    pub stats: serde_json::Value,
}

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct PlaywrightSuite {
    pub title: String,
    pub file: String,
    #[serde(default)]
    pub line: u32,
    #[serde(default)]
    pub column: u32,
    #[serde(default)]
    pub specs: Vec<PlaywrightSpec>,
}

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct PlaywrightSpec {
    pub title: String,
    pub file: String,
    pub line: Option<u32>,
    pub column: Option<u32>,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub tests: Vec<serde_json::Value>,
    #[serde(default)]
    pub ok: bool,
}