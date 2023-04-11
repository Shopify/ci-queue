# frozen_string_literal: true

class BacktraceFilters
  PATTERNS = [
    # truffleruby has some extra lines before the usual ruby ones:
    # "<internal:core> core/numeric.rb:182:in `math_coerce'"
    %r{^<internal:},
  ]

  def initialize(original_filter)
    @original_filter = original_filter
  end

  def add_filter(*args)
    @original_filter.add_filter(*args)
  end

  def filter(backtrace)
    backtrace = @original_filter.filter(backtrace) if @original_filter

    backtrace.reject do |line|
      PATTERNS.any? { |pattern| line.match?(pattern) }
    end
  end
end
