# frozen_string_literal: true

require 'open3'
require 'pathname'
require 'timeout'

RSpec.describe Kupcad do
  let(:forever) { "while true\nend\ncube(1)" }

  describe '.library_version' do
    it 'is the gem version' do
      expect(described_class.library_version).to eq(Kupcad::VERSION)
    end
  end

  describe 'FORMATS' do
    it 'are the formats the library builds in, each a Symbol' do
      expect(described_class::FORMATS).to include(:stl, :'3mf', :glb, :step, :svg)
      expect(described_class::FORMATS).to all(be_a(Symbol))
    end
  end

  describe '.build' do
    it 'builds the model in every format, binary' do
      described_class::FORMATS.each do |format|
        model = described_class.build('cube(10)', format:)
        expect(model.format).to eq(format)
        expect(model.data.encoding).to eq(Encoding::BINARY)
        expect(model.data).not_to be_empty
      end
    end

    it 'takes the format as a String too' do
      expect(described_class.build('cube(1)', format: 'glb').format).to eq(:glb)
    end

    it 'takes the parameters by name, and keeps what the script prints' do
      source = <<~KUP
        width = param(:width, default: 5)
        thread = param(:thread, default: :m3, validate: { in: [:m3, :m4] })
        holes = param(:holes, default: [[0, 0]])
        puts width, thread, holes[1][0]
        cube(width)
      KUP
      model = described_class.build(source, params: { width: 20, thread: :m4, holes: [[5, 5], [35, 5]] })
      expect(model.report.output).to eq("20\nm4\n35\n")
    end

    it 'fails the script with a value its parameter refuses, saying which' do
      source = "width = param(:width, default: 5, validate: { min: 1 })\ncube(width)"
      expect { described_class.build(source, params: { width: 0 }) }
        .to raise_error(Kupcad::ScriptError, /\AValueError: .*width/)
    end

    it 'reads the files given with it, text and binary' do
      block = described_class.build('cube(2)').data
      source = <<~KUP
        import { side } from "./lib/sizes.kup"
        block = import_stl("parts/block.stl")
        puts side, block.volume
        block + cube(side)
      KUP
      files = { 'lib/sizes.kup' => "def side = 12\nexport side", 'parts/block.stl' => block }
      expect(described_class.build(source, files:).report.output).to eq("12\n8\n")
    end

    it 'reads a source, and the paths of its files, in the encoding they say they are in' do
      source = "import { side } from \"./lib/größe.kup\"\nputs \"café\"\ncube(side)".encode(Encoding::ISO_8859_1)
      files = { 'lib/größe.kup'.encode(Encoding::ISO_8859_1) => "def side = 2\nexport side" }
      expect(described_class.build(source, files:).report.output).to eq("café\n")
      expect(described_class.build('cube(1)'.encode(Encoding::UTF_16LE)).data).not_to be_empty
    end

    it 'reports what the script warned of, where, and in which file' do
      files = { 'lib/walls.kup' => "def wall\n  warn(\"thin wall\")\n  cube(1)\nend\nexport wall" }
      model = described_class.build("import { wall } from \"./lib/walls.kup\"\nwarn(\"mine\")\nwall()", files:)
      expect(model.report.warnings).to eq(
        [Kupcad::RunWarning.new(message: 'mine', line: 2, column: 1, file: nil),
         Kupcad::RunWarning.new(message: 'thin wall', line: 2, column: 3, file: 'lib/walls.kup')]
      )
    end

    it 'keeps the start of what a script prints past 64 KB, and says so' do
      report = described_class.build("(1..10000).each { |i| puts \"line \#{i}\" }\ncube(1)").report
      expect(report.output_cut).to be(true)
      expect(report.output).to start_with("line 1\nline 2\n")
    end

    it 'compresses the meshes with Draco when asked' do
      model = described_class.build('sphere(r: 5)', format: :glb, draco: true)
      expect(model.data).to include('KHR_draco_mesh_compression')
      expect(described_class.build('sphere(r: 5)', format: :glb, draco: nil).data).not_to include('KHR_draco')
    end

    it 'raises ScriptError where the script fails, with what it printed until then' do
      expect { described_class.build("puts \"before\"\nraise \"Plate too thin\"") }.to raise_error(
        Kupcad::ScriptError, 'RuntimeError: Plate too thin'
      ) { |error| expect(error.report.output).to eq("before\n") }
      expect { described_class.build("x = 1\ny = )") }.to raise_error(Kupcad::ScriptError, /\A2:5: /)
    end

    it 'keeps a NUL the message quotes' do
      expect { described_class.build('raise "a\\0b"') }.to raise_error(Kupcad::ScriptError, "RuntimeError: a\0b")
    end

    it 'raises ScriptError for a source that is not UTF-8' do
      expect { described_class.build("cube(1) \xFF") }.to raise_error(Kupcad::ScriptError)
    end

    it 'raises ArgumentError for a format that is not one, and parameters JSON or the library cannot hold' do
      expect { described_class.build('cube(1)', format: :stp) }.to raise_error(ArgumentError, /:stp isn't a format/)
      expect { described_class.build('cube(1)', format: "stl\0") }.to raise_error(ArgumentError)
      expect { described_class.build('cube(1)', params: { width: Float::NAN }) }.to raise_error(ArgumentError)
      deep = 101.times.reduce(1) { |value, _| [value] }
      expect { described_class.build('cube(1)', params: { holes: deep }) }.to raise_error(ArgumentError)
      # Values by name, refused by the library itself
      expect { described_class.build('cube(1)', params: [['width', 1]]) }.to raise_error(ArgumentError, /object/)
    end

    it 'raises ArgumentError for a limit that is not a positive number' do
      expect { described_class.build('cube(1)', memory_limit: -1) }.to raise_error(ArgumentError, /memory_limit/)
      expect { described_class.build('cube(1)', memory_limit: 1.5) }.to raise_error(ArgumentError, /memory_limit/)
      [0, Float::NAN, Complex(1, 0)].each do |timeout|
        expect { described_class.build('cube(1)', timeout:) }.to raise_error(ArgumentError, /timeout/)
      end
    end

    it 'takes a limit past what the library holds as none' do
      [{ timeout: Float::INFINITY }, { timeout: 10**30 }, { memory_limit: 2**70 }].each do |limits|
        expect(described_class.build('cube(1)', **limits).data).not_to be_empty
      end
    end

    it 'raises TypeError for a source, or the content of a file, that is not a String' do
      expect { described_class.build(nil) }.to raise_error(TypeError, /source is NilClass/)
      expect { described_class.format(nil) }.to raise_error(TypeError, /source is NilClass/)
      expect { described_class.build('cube(1)', files: { 'a.kup' => Pathname('a.kup') }) }
        .to raise_error(TypeError, /a\.kup is Pathname/)
    end

    it 'refuses a file past 4 GiB, the most its length holds' do
      content = +'cube(1)'
      allow(content).to receive(:bytesize).and_return(2**32)
      expect { described_class.build('cube(1)', files: { 'big.kup' => content }) }
        .to raise_error(ArgumentError, /big\.kup is past 4 GiB/)
    end

    it 'stops a script that holds more than its memory limit, however small' do
      [1_000_000, 1].each do |limit|
        expect { described_class.build("a = (1..2_000_000).to_a\ncube(1)", memory_limit: limit) }.to raise_error(
          Kupcad::ScriptError, /\AOutOfMemoryError: /
        )
      end
    end

    it 'stops a script that runs longer than its timeout' do
      expect { described_class.build(forever, timeout: 0.1) }.to raise_error(
        Kupcad::ScriptError, /\ATime limit: the run took longer than 100 ms/
      )
      # Rounded to whole milliseconds, so a float's error can't add one (2.007 s is 2007.0000000000002 ms)
      expect { described_class.build(forever, timeout: 0.0141) }.to raise_error(Kupcad::ScriptError, / 14 ms/)
    end

    it 'frees its result when an interrupt comes while it runs, and raises the interrupt after' do
      allow(Kupcad::Native).to receive(:kupcad_result_free).and_call_original
      expect { Timeout.timeout(0.05) { described_class.build(forever, timeout: 0.3) } }.to raise_error(Timeout::Error)
      expect(Kupcad::Native).to have_received(:kupcad_result_free).once
    end

    it 'lets other threads run while it builds' do
      ticks = 0
      ticker = Thread.new do
        loop do
          ticks += 1
          sleep 0.01
        end
      end
      expect { described_class.build(forever, timeout: 0.3) }.to raise_error(Kupcad::ScriptError)
      ticker.kill
      expect(ticks).to be > 10
    end

    it 'builds on several threads at once' do
      threads = (1..4).map { |side| Thread.new { described_class.build("puts #{side}\ncube(#{side})").report.output } }
      expect(threads.map(&:value)).to eq(%W[1\n 2\n 3\n 4\n])
    end

    it "builds every example the repository ships, with each one's defaults" do
      Dir[File.join(EXAMPLES, '*.kup')].each do |path|
        drawing = DRAWINGS.include?(File.basename(path))
        model = described_class.build(File.read(path, encoding: Encoding::UTF_8), format: drawing ? :svg : :glb)
        expect(model.data).to start_with(drawing ? '<?xml' : 'glTF'), path
      end
    end
  end

  describe 'errors' do
    it 'are StandardErrors, a script error a Kupcad::Error' do
      expect(Kupcad::ScriptError.ancestors).to include(Kupcad::Error, StandardError)
    end
  end

  describe 'loading' do
    it 'raises LoadError without the library, saying what to do' do
      lib = File.dirname(described_class.method(:build).source_location.first)
      _, stderr, status = Open3.capture3({ 'KUPCAD_LIBRARY' => '/nowhere/libkupcad.so' },
                                         Gem.ruby, '-I', lib, '-e', 'require "kupcad"')
      expect(status).not_to be_success
      expect(stderr).to include('/nowhere/libkupcad.so not found', 'KUPCAD_LIBRARY')
    end
  end

  describe '.format' do
    it 'formats as kupcad fmt does' do
      expect(described_class.format('cube( 1 )')).to eq("cube(1)\n")
      expect(described_class.format('')).to eq('')
    end

    it 'raises ScriptError where the source does not parse, without a report: nothing ran' do
      expect { described_class.format('x = )') }.to raise_error(Kupcad::ScriptError, /\A1:5: /) { |error|
        expect(error.report).to be_nil
      }
    end
  end

  describe '.check' do
    it 'finds what kupcad check finds' do
      finding = described_class.check("x = 1\ncube(1)").first
      expect(finding).to have_attributes(rule: 'unused-variable', severity: 'warning', line: 1, column: 1)
      expect(finding.fix).to include(title: "Rename 'x' to '_x'", safe: true)
    end

    it 'finds a syntax error, as a finding without a rule' do
      expect(described_class.check('x = )').first).to have_attributes(severity: 'error', rule: nil,
                                                                      code: 'invalid-expression')
    end

    it 'finds nothing in a clean script' do
      expect(described_class.check('cube(1)')).to be_empty
    end
  end

  describe '.params' do
    it 'reads the schema kupcad doc prints' do
      schema = described_class.params("# @title Plate\nwidth = param(:width, default: 40)\ncube(width)")
      expect(schema[:meta][:title]).to eq('Plate')
      expect(schema[:parameters].map { |parameter| parameter[:name] }).to eq(['width'])
    end
  end
end
