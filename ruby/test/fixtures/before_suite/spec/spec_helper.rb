# frozen_string_literal: true
RSpec.configure do |config|
  config.backtrace_inclusion_patterns << %r{/test/fixtures/}
  config.before(:suite) do
    raise "Whoops"
  end
end
