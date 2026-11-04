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

    # Gem platform => the library's file name, its binary format and its CPU
    PLATFORMS = {
      'x86_64-linux-gnu' => ['libkupcad.so', :elf, 'x86_64'],
      'aarch64-linux-gnu' => ['libkupcad.so', :elf, 'aarch64'],
      'x86_64-darwin' => ['libkupcad.dylib', :macho, 'x86_64'],
      'arm64-darwin' => ['libkupcad.dylib', :macho, 'aarch64'],
      'x64-mingw-ucrt' => ['kupcad.dll', :pe, 'x86_64'],
      'aarch64-mingw-ucrt' => ['kupcad.dll', :pe, 'aarch64']
    }.freeze

    ELF_MACHINES = { 0x3E => 'x86_64', 0xB7 => 'aarch64' }.freeze
    MACHO_CPU_TYPES = { 0x01000007 => 'x86_64', 0x0100000C => 'aarch64' }.freeze
    PE_MACHINES = { 0x8664 => 'x86_64', 0xAA64 => 'aarch64' }.freeze

    # [:elf, :macho or :pe, "x86_64" or "aarch64"] from a 64-bit library's header, or nil when
    # the file is something else
    def self.binary_format(path)
      header = File.binread(path, 64).to_s
      return nil if header.bytesize < 64

      if header.start_with?("\x7FELF".b)
        [:elf, ELF_MACHINES[header.byteslice(18, 2).unpack1('v')]]
      elsif header.start_with?("\xCF\xFA\xED\xFE".b)
        [:macho, MACHO_CPU_TYPES[header.byteslice(4, 4).unpack1('V')]]
      elsif header.start_with?('MZ')
        pe = File.binread(path, 6, header.byteslice(0x3C, 4).unpack1('V')).to_s
        [:pe, PE_MACHINES[pe.byteslice(4, 2).unpack1('v')]] if pe.start_with?("PE\0\0".b)
      end
    end

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
      "lib/kupcad/native/#{PLATFORMS.fetch(platform).first}"
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

      name, *expected = PLATFORMS.fetch(platform)
      raise Error, "#{@library} isn't named #{name}, as #{platform}'s library is" unless File.basename(@library) == name

      actual = self.class.binary_format(@library)
      return true if actual == expected

      raise Error, "#{@library} is built for #{actual ? actual.join(' ') : 'an unknown format'}, not #{platform}"
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
