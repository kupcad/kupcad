# frozen_string_literal: true

RSpec.describe Kupcad do
  describe '.library_version' do
    it 'is the gem version' do
      expect(described_class.library_version).to eq(Kupcad::VERSION)
    end
  end

  describe '.build' do
    it 'builds the model in every format' do
      described_class::FORMATS.each do |format|
        model = described_class.build('cube(10)', format:)
        expect(model.format).to eq(format)
        expect(model.data.encoding).to eq(Encoding::BINARY)
        expect(model.data).not_to be_empty
      end
    end

    it 'takes the parameters by name, and keeps what the script prints' do
      source = <<~KUP
        width = param(:width, default: 5)
        thread = param(:thread, default: :m3, validate: { in: [:m3, :m4] })
        puts width, thread
        cube(width)
      KUP
      model = described_class.build(source, params: { width: 20, thread: :m4 })
      expect(model.report.output).to eq("20\nm4\n")
    end

    it 'reads the files given with it' do
      source = "import { side } from \"./lib/sizes.kup\"\nputs side\ncube(side)"
      model = described_class.build(source, files: { 'lib/sizes.kup' => "def side = 12\nexport side" })
      expect(model.report.output).to eq("12\n")
    end

    it 'reports what the script warned of, where' do
      model = described_class.build("cube(1)\nwarn(\"thin wall\")\ncube(1)")
      expect(model.report.warnings).to eq([Kupcad::Warning.new(message: 'thin wall', line: 2, column: 1, file: nil)])
    end

    it 'raises ScriptError where the script fails, with what it printed until then' do
      expect { described_class.build("puts \"before\"\nraise \"Plate too thin\"") }.to raise_error(
        Kupcad::ScriptError, 'RuntimeError: Plate too thin'
      ) { |error| expect(error.report.output).to eq("before\n") }
      expect { described_class.build("x = 1\ny = )") }.to raise_error(Kupcad::ScriptError, /\A2:5: /)
    end

    it 'raises ArgumentError for a format that is not one, and parameters JSON cannot hold' do
      expect { described_class.build('cube(1)', format: :stp) }.to raise_error(ArgumentError, /'stp' isn't a format/)
      expect { described_class.build('cube(1)', params: { width: Float::NAN }) }.to raise_error(ArgumentError)
    end

    it 'stops a script that holds more than its memory limit' do
      expect { described_class.build("a = (1..2_000_000).to_a\ncube(1)", memory_limit: 1_000_000) }.to raise_error(
        Kupcad::ScriptError, /\AOutOfMemoryError: /
      )
    end

    it 'builds on several threads at once' do
      threads = (1..4).map { |side| Thread.new { described_class.build("puts #{side}\ncube(#{side})").report.output } }
      expect(threads.map(&:value)).to eq(%W[1\n 2\n 3\n 4\n])
    end

    it "builds every example the repository ships, with each one's defaults" do
      Dir[File.join(EXAMPLES, '*.kup')].each do |path|
        drawing = DRAWINGS.include?(File.basename(path))
        model = described_class.build(File.read(path), format: drawing ? :svg : :glb)
        expect(model.data).to start_with(drawing ? '<?xml' : 'glTF'), path
      end
    end
  end

  describe '.format' do
    it 'formats as kupcad fmt does' do
      expect(described_class.format('cube( 1 )')).to eq("cube(1)\n")
    end

    it 'raises ScriptError where the source does not parse' do
      expect { described_class.format('x = )') }.to raise_error(Kupcad::ScriptError, /\A1:5: /)
    end
  end

  describe '.check' do
    it 'finds what kupcad check finds' do
      finding = described_class.check("x = 1\ncube(1)").first
      expect(finding).to have_attributes(rule: 'unused-variable', severity: 'warning', line: 1, column: 1)
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
