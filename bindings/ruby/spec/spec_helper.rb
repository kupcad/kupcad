# frozen_string_literal: true

require 'ffi'

# KUPCAD_INSTALLED_GEM=1 tests the installed gem, and the library it carries, instead of lib/:
# a platform gem, on CI. rspec puts lib/ on the load path, so it is taken off first.
if ENV['KUPCAD_INSTALLED_GEM']
  $LOAD_PATH.delete(File.expand_path('../lib', __dir__))
  gem 'kupcad'
else
  # The checkout's own libkupcad (`zig build lib` in core/), unless KUPCAD_LIBRARY names another
  ENV['KUPCAD_LIBRARY'] ||= File.expand_path(
    "../../../core/zig-out/lib/#{FFI::Platform::LIBPREFIX}kupcad.#{FFI::Platform::LIBSUFFIX}", __dir__
  )
end
require 'kupcad'

# The repository's example scripts, and those of them that are drawings, which build as SVG
EXAMPLES = File.expand_path('../../../examples', __dir__)
DRAWINGS = %w[cup.kup].freeze

RSpec.configure do |config|
  config.example_status_persistence_file_path = '.rspec_status'
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  # The packer's specs need the source tree and the library it was built from
  config.filter_run_excluding :source_tree if ENV['KUPCAD_INSTALLED_GEM']
end
