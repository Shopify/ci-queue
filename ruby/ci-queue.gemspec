# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'ci/queue/version'
require 'pathname'

dir = Pathname.new(CI::Queue::RELEASE_SCRIPTS_ROOT).relative_path_from(Pathname.new(__dir__).realpath)
lua_scripts = Dir[dir.join('*.lua').to_s]

Gem::Specification.new do |spec|
  spec.name          = 'ci-queue'
  spec.version       = CI::Queue::VERSION
  spec.authors       = ["Jean Boussier"]
  spec.email         = ["jean.boussier@shopify.com"]

  spec.summary       = %q{Distribute tests over many workers using a queue}
  spec.description   = %q{To parallelize your CI without having to balance your tests}
  spec.homepage      = 'https://github.com/Shopify/ci-queue'
  spec.license       = 'MIT'

  spec.files         = lua_scripts + `git ls-files -z`.split("\x0").reject do |f|
    f.match(%r{^(test|spec|features)/})
  end

  spec.bindir        = 'exe'
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_development_dependency 'bundler', '~> 1.13'
  spec.add_development_dependency 'rake', "~> 10.0"
  spec.add_development_dependency 'minitest', '~> 5.9.1'
  spec.add_development_dependency 'redis', '~> 3.3'
  spec.add_development_dependency 'simplecov', '~> 0.12'
  spec.add_development_dependency 'minitest-reporters', '~> 1.1'
end
