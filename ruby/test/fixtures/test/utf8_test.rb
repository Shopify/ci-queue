# frozen_string_literal: true
require 'test_helper'
require 'active_support/all'

class Utf8Test < ActiveSupport::TestCase
  test 'doesn’t allow requests from inactive users' do
     refute true
   end
end
