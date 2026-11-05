# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'rubygems/package'
require 'tmpdir'
require_relative '../../rakelib/native_gem'

RSpec.describe Kupcad::NativeGem, :source_tree do
  let(:platform) { 'arm64-darwin' }
  # A library staged as the release stages it, the notices and the license texts beside it:
  # stand-ins, as the packer only carries them (which texts they are is collect-licenses.sh's
  # business, and whether the library runs is the release's, installing the gem on its system)
  let(:stage) { Dir.mktmpdir }
  let(:library) do
    File.write(File.join(stage, 'libkupcad.dylib'), 'a library')
    File.write(File.join(stage, 'THIRD_PARTY_NOTICES.md'), "# Third-party notices\n")
    FileUtils.mkdir_p(File.join(stage, 'licenses', 'manifold'))
    File.write(File.join(stage, 'licenses', 'manifold', 'LICENSE'), "Apache License\n")
    File.join(stage, 'libkupcad.dylib')
  end

  after { FileUtils.remove_entry(stage) }

  it 'packs the library and its notices into a gem of its platform' do
    path = Gem::DefaultUserInteraction.use_ui(Gem::SilentUI.new) do
      described_class.new(platform, library).build(File.join(stage, 'pkg'))
    end
    gem = Gem::Package.new(path)
    expect(gem.spec.platform.to_s).to eq('arm64-darwin')
    expect(gem.contents).to include('lib/kupcad/native/libkupcad.dylib', 'lib/kupcad.rb', 'lib/kupcad/native.rb',
                                    'lib/kupcad/version.rb', 'sig/kupcad.rbs', 'README.md', 'LICENSE',
                                    'lib/kupcad/native/THIRD_PARTY_NOTICES.md',
                                    'lib/kupcad/native/licenses/manifold/LICENSE')
  end

  it 'refuses a library without the notices beside it' do
    File.delete(File.join(File.dirname(library), 'THIRD_PARTY_NOTICES.md'))
    expect { described_class.new(platform, library).validate! }.to raise_error(described_class::Error, /NOTICES/)
  end

  it "refuses a library not named as its platform's is" do
    expect { described_class.new('x86_64-linux-gnu', library).validate! }
      .to raise_error(described_class::Error, /libkupcad\.so/)
  end

  it 'refuses a platform it has no gem for' do
    expect { described_class.new('x86_64-linux-musl', library) }
      .to raise_error(described_class::Error, /unknown platform/)
  end

  describe 'rake native:gem' do
    # The task as the release runs it on each system, PLATFORM and LIBRARY its command line's alone
    def rake(*arguments)
      Open3.capture3({ 'PLATFORM' => nil, 'LIBRARY' => nil }, Gem.ruby, Gem.bin_path('rake', 'rake'),
                     'native:gem', *arguments, chdir: File.expand_path('../..', __dir__))
    end

    it 'takes the library path whole, backslashes and commas too, as a Windows path is' do
      library = File.join(Dir.tmpdir, 'kupcad\\lib,1', 'libkupcad.dylib')
      _, stderr, status = rake('PLATFORM=arm64-darwin', "LIBRARY=#{library}")
      expect(status).not_to be_success
      expect(stderr).to include("#{File.expand_path(library)} not found")
    end

    it 'says how to call it when the platform or the library is missing' do
      _, stderr, status = rake('PLATFORM=arm64-darwin')
      expect(status).not_to be_success
      expect(stderr).to include('usage: rake native:gem PLATFORM=... LIBRARY=...')
    end
  end
end
