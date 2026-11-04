# frozen_string_literal: true

require 'rubygems/package'
require 'fileutils'
require 'tmpdir'
require_relative '../../rakelib/native_gem'

RSpec.describe Kupcad::NativeGem, :source_tree do
  # The library in use, staged as the release stages it: the notices and the license texts
  # beside it (stand-ins: which texts they are is collect-licenses.sh's business)
  let(:library) do
    stage = Dir.mktmpdir
    FileUtils.cp(ENV.fetch('KUPCAD_LIBRARY'), stage)
    File.write(File.join(stage, 'THIRD_PARTY_NOTICES.md'), "# Third-party notices\n")
    FileUtils.mkdir_p(File.join(stage, 'licenses', 'manifold'))
    File.write(File.join(stage, 'licenses', 'manifold', 'LICENSE'), "Apache License\n")
    File.join(stage, File.basename(ENV.fetch('KUPCAD_LIBRARY')))
  end
  # The platform the library in use is built for
  let(:platform) do
    format = described_class.binary_format(library)
    described_class::PLATFORMS.find { |_platform, (_name, *built_for)| built_for == format }.first
  end

  it 'packs the library into a gem of its platform' do
    Dir.mktmpdir do |out|
      path = Gem::DefaultUserInteraction.use_ui(Gem::SilentUI.new) { described_class.new(platform, library).build(out) }
      gem = Gem::Package.new(path)
      expect(gem.spec.platform.to_s).to eq(Gem::Platform.new(platform).to_s)
      expect(gem.contents).to include(described_class.new(platform, library).library_path, 'lib/kupcad.rb', 'LICENSE',
                                      'lib/kupcad/native/THIRD_PARTY_NOTICES.md',
                                      'lib/kupcad/native/licenses/manifold/LICENSE')
    end
  end

  it 'refuses a library without the notices beside it' do
    bare = File.join(Dir.mktmpdir, File.basename(library))
    FileUtils.cp(library, bare)
    expect { described_class.new(platform, bare).validate! }.to raise_error(described_class::Error, /NOTICES/)
  end

  it 'refuses a library built for another platform' do
    other = described_class::PLATFORMS.keys.find do |candidate|
      described_class::PLATFORMS[candidate].first == File.basename(library) && candidate != platform
    end
    expect { described_class.new(other, library).validate! }.to raise_error(described_class::Error, /is built for/)
  end
end
