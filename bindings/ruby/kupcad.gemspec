# frozen_string_literal: true

require_relative 'lib/kupcad/version'

Gem::Specification.new do |spec|
  spec.name = 'kupcad'
  spec.version = Kupcad::VERSION
  spec.authors = ['Oleksii Vasyliev']
  spec.email = ['le0pard@users.noreply.github.com']
  spec.license = 'AGPL-3.0-only'

  spec.summary = 'KupCAD for Ruby: build parametric CAD models from KupCAD scripts'
  spec.description = [
    'Builds the model of a KupCAD script, with its parameters, as STL, 3MF, glTF, OBJ, STEP, SVG or DXF,',
    'and formats, lints and reads the parameters of scripts, in process, through libkupcad,',
    'the KupCAD core as a C library, which each platform gem carries.'
  ].join(' ')
  spec.homepage = 'https://kupcad.org'
  spec.required_ruby_version = '>= 3.2'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/kupcad/kupcad/tree/main/bindings/ruby'
  spec.metadata['documentation_uri'] = 'https://docs.kupcad.org'
  spec.metadata['changelog_uri'] = 'https://github.com/kupcad/kupcad/releases'
  spec.metadata['bug_tracker_uri'] = 'https://github.com/kupcad/kupcad/issues'
  spec.metadata['rubygems_mfa_required'] = 'true'

  # The library itself goes into each platform gem (rakelib/native_gem.rb)
  spec.files = Dir.chdir(__dir__) { Dir['lib/**/*.rb', 'sig/**/*.rbs', 'README.md', 'LICENSE'] }
  spec.require_paths = ['lib']

  spec.add_dependency 'ffi', '~> 1.15'
end
