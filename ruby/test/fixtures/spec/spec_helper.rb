RSpec.configure do |config|
  config.backtrace_exclusion_patterns << %r{(rspec|ci)/queue}
end
