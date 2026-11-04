# frozen_string_literal: true

require 'json'
require_relative 'kupcad/version'
require_relative 'kupcad/native'

# KupCAD from Ruby: build the model of a KupCAD script, with its parameters, in any format the
# CLI exports, and format, lint and read the parameters of scripts. It runs libkupcad, the
# KupCAD core as a C library, in the process; a script reads only the files given with it.
#
#   model = Kupcad.build(File.read('bracket.kup'), format: :stl, params: { width: 60 })
#   File.binwrite('bracket.stl', model.data)
module Kupcad
  class Error < StandardError; end

  # The script doesn't parse or compile, raises, or leaves no model to export. The message
  # says where and why: "2:5: Invalid expression ...", "RuntimeError: Plate too thin".
  class ScriptError < Error
    # What the script printed and warned of before it failed (a Report); nil when it didn't run
    attr_reader :report

    def initialize(message, report = nil)
      super(message)
      @report = report
    end
  end

  # The formats a model can be built in
  FORMATS = %i[stl 3mf glb gltf obj step svg dxf].freeze

  # Something the script warned of, at its line and column (1-based; nil where it wasn't
  # running, as the model was meshed), in `file`, the imported file whose code warned (nil for
  # the script's own)
  Warning = Data.define(:message, :line, :column, :file)

  # What a run printed (`puts`, `print`, `warn`), up to 64 KB (`output_cut` past them), and
  # what it warned of
  Report = Data.define(:output, :output_cut, :warnings) do
    def self.from_json(json)
      fields = JSON.parse(json, symbolize_names: true)
      new(output: fields[:output], output_cut: fields[:outputCut],
          warnings: fields[:warnings].map { |warning| Warning.new(**warning) })
    end
  end

  # A built model: its bytes in `format` (binary), and the run's report
  Model = Data.define(:data, :format, :report)

  # A lint finding or a syntax error, as `kupcad check --format json` gives it: its severity
  # ("error", "warning" or "info"), its rule (nil for a syntax error), its code, its message,
  # where it starts and ends (1-based), and its fix (a Hash, or nil)
  Finding = Data.define(:severity, :rule, :code, :message, :line, :column, :end_line, :end_column, :fix)

  class << self
    # The version of the libkupcad loaded: the gem's own, unless KUPCAD_LIBRARY names another
    def library_version
      JSON.parse(text(Native.kupcad_version))['version']
    end

    # `source` formatted, as `kupcad fmt` formats it. Raises ScriptError when it doesn't parse.
    def format(source)
      pointer, length = Native.buffer(source)
      text(Native.kupcad_format(pointer, length))
    end

    # The findings of `source`: lint findings and syntax errors, an Array of Finding
    def check(source)
      pointer, length = Native.buffer(source)
      JSON.parse(text(Native.kupcad_check(pointer, length)), symbolize_names: true).map do |finding|
        Finding.new(severity: finding[:severity], rule: finding[:rule], code: finding[:code],
                    message: finding[:message], line: finding[:line], column: finding[:column],
                    end_line: finding[:endLine], end_column: finding[:endColumn], fix: finding[:fix])
      end
    end

    # The parameters `source` declares and its metadata, the schema `kupcad doc` prints:
    # { meta: { title: ... }, parameters: [{ name: ..., type: ..., default: ... }] }
    def params(source)
      pointer, length = Native.buffer(source)
      JSON.parse(text(Native.kupcad_params(pointer, length)), symbolize_names: true)
    end

    # Runs `source` and builds its model in `format` (one of FORMATS), a Model.
    #
    # params: the parameters' values by name, as `kupcad build -p` takes them
    #   ({ width: 60, label: 'A', holes: [[5, 5], [35, 5]] }).
    # files: the files the script imports, by their path from its folder
    #   ({ 'lib/gears.kup' => File.read('lib/gears.kup') }).
    # memory_limit: the most memory, in bytes, the script may hold; nil for no limit.
    # draco: compress a GLB's or a glTF's meshes with Draco.
    #
    # Raises ScriptError when the script fails, with what it printed and warned of until then,
    # and ArgumentError for a format that isn't one or parameters JSON can't hold.
    def build(source, format: :stl, params: {}, files: {}, memory_limit: nil, draco: false)
      source_pointer, source_length = Native.buffer(source)
      params_pointer, params_length = Native.buffer(params_json(params))
      files_pointer, files_length = Native.buffer(pack(files))
      data, report = take(Native.kupcad_build(source_pointer, source_length, format.to_s, params_pointer,
                                              params_length, files_pointer, files_length, memory_limit || 0, draco))
      Model.new(data:, format: format.to_sym, report: Report.from_json(report))
    end

    private

    # The data of a call's result, as UTF-8 text; raises what failed
    def text(result)
      take(result).first.force_encoding(Encoding::UTF_8)
    end

    # [data, report] of a call's result, the data binary; raises what failed
    def take(result)
      status, data, message, report = Native.take(result)
      case status
      when :ok then [data, report]
      when :script_error then raise ScriptError.new(message, report && Report.from_json(report))
      when :invalid_argument then raise ArgumentError, message
      when :out_of_memory then raise NoMemoryError, message
      else raise Error, message
      end
    end

    def params_json(params)
      params.empty? ? nil : JSON.generate(params)
    rescue JSON::GeneratorError => e
      raise ArgumentError, "parameters: #{e.message}"
    end

    # The files packed as kupcad.h describes: each its path's length, its path, its content's
    # length and its content, each length 4 bytes, little-endian
    def pack(files)
      files.each_with_object(String.new(encoding: Encoding::BINARY)) do |(path, content), packed|
        [path.to_s, content.to_s].each { |field| packed << [field.bytesize].pack('V') << field.b }
      end
    end
  end
end
