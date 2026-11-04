# frozen_string_literal: true

require 'fileutils'
require 'rubygems/package'
require 'tmpdir'

module Kupcad
  # Packs a platform gem around a libkupcad built for that platform (`zig build lib`, as the
  # release's build job runs it): the gem carries the library in lib/kupcad/native/, so
  # installing it compiles nothing, and beside it THIRD_PARTY_NOTICES.md and the license texts
  # of what it is built from, which core/scripts/collect-licenses.sh puts beside the library.
  class NativeGem
    class Error < StandardError; end

    # Gem platform => the library's file name there. Whether a library is built for its
    # platform the release checks by installing the gem there and running the specs on it.
    PLATFORMS = {
      'x86_64-linux-gnu' => 'libkupcad.so',
      'aarch64-linux-gnu' => 'libkupcad.so',
      'x86_64-darwin' => 'libkupcad.dylib',
      'arm64-darwin' => 'libkupcad.dylib',
      'x64-mingw-ucrt' => 'kupcad.dll',
      'aarch64-mingw-ucrt' => 'kupcad.dll'
    }.freeze

    attr_reader :platform

    def initialize(platform, library, root: File.expand_path('..', __dir__))
      unless PLATFORMS.key?(platform)
        raise Error, "unknown platform #{platform.inspect}, use one of #{PLATFORMS.keys.join(', ')}"
      end

      @platform = platform
      @library = File.expand_path(library)
      @root = root
    end

    # Where the gem carries the library, which lib/kupcad/native.rb loads
    def library_path
      "lib/kupcad/native/#{PLATFORMS.fetch(platform)}"
    end

    # The files beside the library that go with it, by their path in the gem
    def native_files
      folder = File.dirname(@library)
      notices = Dir[File.join(folder, 'THIRD_PARTY_NOTICES.md'), File.join(folder, 'licenses', '**', '*')]
      files = notices.select { |path| File.file?(path) }.sort.to_h do |path|
        [path, "lib/kupcad/native/#{path.delete_prefix("#{folder}/")}"]
      end
      files.merge(@library => library_path)
    end

    def spec
      # dup copies the file list, so the cached source spec stays as it is
      spec = Gem::Specification.load(File.join(@root, 'kupcad.gemspec')).dup
      spec.platform = Gem::Platform.new(platform)
      spec.files = spec.files + native_files.values
      spec
    end

    def validate!
      raise Error, "#{@library} not found: build it with `zig build lib` in core/" unless File.file?(@library)

      notices = File.join(File.dirname(@library), 'THIRD_PARTY_NOTICES.md')
      raise Error, "#{notices} not found: collect-licenses.sh puts it beside the library" unless File.file?(notices)

      name = PLATFORMS.fetch(platform)
      raise Error, "#{@library} isn't named #{name}, as #{platform}'s library is" unless File.basename(@library) == name
    end

    # Writes pkg/kupcad-VERSION-PLATFORM.gem and returns its path
    def build(out_dir = File.join(@root, 'pkg'))
      validate!
      gemspec = spec
      out_dir = File.expand_path(out_dir)
      FileUtils.mkdir_p(out_dir)
      sources = native_files.invert
      Dir.mktmpdir('kupcad-gem') do |stage|
        gemspec.files.each do |path|
          target = File.join(stage, path)
          FileUtils.mkdir_p(File.dirname(target))
          # cp follows LICENSE, a link to the repository's
          FileUtils.cp(sources.fetch(path) { File.join(@root, path) }, target)
        end
        file_name = Dir.chdir(stage) { Gem::Package.build(gemspec) }
        FileUtils.mv(File.join(stage, file_name), out_dir)
        File.join(out_dir, file_name)
      end
    end
  end
end
