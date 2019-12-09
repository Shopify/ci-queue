# frozen_string_literal: true
require 'test_helper'

class LeakyTest < Minitest::Test
  class << self
    attr_accessor :leaked
  end

  self.leaked = false

  50.times do |i|
    class_eval(%Q(
      def test_useless_#{i}
        assert true
      end
    ))
  end

  def test_introduce_leak
    self.class.leaked = true
    assert true
  end

  def test_sensible_to_leak
    assert_equal false, self.class.leaked
  end

  def test_harmless_test
    assert true
  end

  def test_broken_test
    assert false
  end
end
