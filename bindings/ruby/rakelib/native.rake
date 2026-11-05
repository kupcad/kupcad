# frozen_string_literal: true

require_relative 'native_gem'

namespace :native do
  # The platform and the library come as NAME=value, which Rake keeps as it is: as task
  # arguments (native:gem[PLATFORM,LIBRARY]), a backslash was read as an escape, so a Windows
  # path lost its separators, and a comma in a path split it.
  desc 'Pack a platform gem around a libkupcad built for it, e.g. ' \
       'rake native:gem PLATFORM=arm64-darwin LIBRARY=path/libkupcad.dylib'
  task :gem do
    platform = ENV.fetch('PLATFORM', nil)
    library = ENV.fetch('LIBRARY', nil)
    unless platform && library
      abort 'usage: rake native:gem PLATFORM=... LIBRARY=..., ' \
            "PLATFORM one of #{Kupcad::NativeGem::PLATFORMS.keys.join(', ')}"
    end
    puts "Built #{Kupcad::NativeGem.new(platform, library).build}"
  end
end
