RSpec.configure do |config|
  config.backtrace_exclusion_patterns << %r{(rspec|ci)/queue}
  config.before(:suite) do
    raise "Whoops"
  end
end
