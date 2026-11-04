# frozen_string_literal: true

require_relative 'native_gem'

namespace :native do
  desc 'Pack a platform gem around a libkupcad built for it, e.g. rake native:gem[arm64-darwin,path/libkupcad.dylib]'
  task :gem, %i[platform library] do |_task, args|
    unless args[:platform] && args[:library]
      abort "usage: rake native:gem[PLATFORM,LIBRARY], PLATFORM one of #{Kupcad::NativeGem::PLATFORMS.keys.join(', ')}"
    end
    puts "Built #{Kupcad::NativeGem.new(args[:platform], args[:library]).build}"
  end
end
