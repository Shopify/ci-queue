use std::process::Command;

pub struct RedisTestContext {
  pub build_id: String,
}

impl RedisTestContext {
  pub fn new(test_name: &str) -> Option<Self> {
      if !Self::redis_available() {
          eprintln!("Skipping integration test: Redis not available");
          return None;
      }
      
      let build_id = format!("{}-{}", test_name, std::process::id());
      let context = Self { build_id };
      context.cleanup();
      Some(context)
  }
  
  fn redis_available() -> bool {
      Command::new("redis-cli")
          .arg("ping")
          .output()
          .map(|output| output.status.success())
          .unwrap_or(false)
  }
  
  fn cleanup(&self) {
      let _ = Command::new("redis-cli")
          .arg("--scan")
          .arg("--pattern")
          .arg(&format!("build:{}:*", self.build_id))
          .output()
          .and_then(|output| {
              let keys = String::from_utf8_lossy(&output.stdout);
              for key in keys.lines() {
                  let _ = Command::new("redis-cli")
                      .arg("del")
                      .arg(key)
                      .output();
              }
              Ok(())
          });
  }
}

impl Drop for RedisTestContext {
  fn drop(&mut self) {
      self.cleanup();
  }
}

// Macro to skip tests when Redis is not available
#[macro_export]
macro_rules! redis_test {
  ($context:ident, $body:block) => {
      let Some($context) = crate::utils::RedisTestContext::new(stringify!($context)) else {
          return;
      };
      $body
  };
}
