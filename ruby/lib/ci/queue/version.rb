# frozen_string_literal: true

module CI
  module Queue
    VERSION = '0.17.1'
    DEV_SCRIPTS_ROOT = ::File.expand_path('../../../../../redis', __FILE__)
    RELEASE_SCRIPTS_ROOT = ::File.expand_path('../redis', __FILE__)
  end
end
