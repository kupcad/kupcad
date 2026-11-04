# frozen_string_literal: true

require 'ffi'

module Kupcad
  # libkupcad's C API, as include/kupcad.h in the kupcad repository declares it. The library is
  # the one KUPCAD_LIBRARY names, else the one the platform gem carries in lib/kupcad/native/.
  module Native
    extend FFI::Library

    # The ABI this module declares (KUPCAD_ABI_VERSION): a library that says another is refused
    ABI_VERSION = 1

    LIBRARY = "#{FFI::Platform::LIBPREFIX}kupcad.#{FFI::Platform::LIBSUFFIX}".freeze

    path = ENV.fetch('KUPCAD_LIBRARY') { File.expand_path("native/#{LIBRARY}", __dir__) }
    unless File.file?(path)
      raise LoadError, "#{path} not found: the kupcad gem has no prebuilt library for #{RUBY_PLATFORM}. " \
                       'Set KUPCAD_LIBRARY to a libkupcad you built (`zig build lib` in the kupcad ' \
                       "repository's core/), or run the kupcad CLI."
    end
    ffi_lib path

    enum :status, [:ok, 0, :script_error, :invalid_argument, :out_of_memory, :internal_error]

    attach_function :kupcad_abi_version, [], :uint32
    attach_function :kupcad_version, [], :pointer
    # blocking: they release the GVL while they run, so other threads go on; libkupcad's calls
    # share nothing, so they may run at once
    attach_function :kupcad_format, %i[pointer size_t], :pointer, blocking: true
    attach_function :kupcad_check, %i[pointer size_t], :pointer, blocking: true
    attach_function :kupcad_params, %i[pointer size_t], :pointer, blocking: true
    attach_function :kupcad_build, %i[pointer size_t string pointer size_t pointer size_t uint64 uint64 bool], :pointer,
                    blocking: true
    attach_function :kupcad_result_status, [:pointer], :status
    attach_function :kupcad_result_data, %i[pointer pointer], :pointer
    attach_function :kupcad_result_message, %i[pointer pointer], :pointer
    attach_function :kupcad_result_report, [:pointer], :string
    attach_function :kupcad_result_free, [:pointer], :void

    abi = kupcad_abi_version
    unless abi == ABI_VERSION
      raise LoadError, "#{path} is libkupcad of ABI #{abi}; this gem speaks ABI #{ABI_VERSION}: use the libkupcad " \
                       "of KupCAD #{VERSION}"
    end

    module_function

    # The bytes, in native memory a blocking call may read with the GVL released, and their
    # length; nil for none
    def buffer(bytes)
      return [nil, 0] if bytes.nil? || bytes.empty?

      pointer = FFI::MemoryPointer.new(:uint8, bytes.bytesize)
      pointer.put_bytes(0, bytes)
      [pointer, bytes.bytesize]
    end

    # What a call gave, read and freed: [status, data, message, report]. The data is binary;
    # the message and the report, UTF-8. The data and the message are read by their length:
    # a message can quote a NUL (the report is JSON, which escapes one)
    def take(result)
      length = FFI::MemoryPointer.new(:size_t)
      data = kupcad_result_data(result, length).read_bytes(length.read(:size_t))
      message = kupcad_result_message(result, length)
      message = message.null? ? nil : utf8(message.read_bytes(length.read(:size_t)))
      [kupcad_result_status(result), data, message, utf8(kupcad_result_report(result))]
    ensure
      kupcad_result_free(result)
    end

    def utf8(text)
      text&.force_encoding(Encoding::UTF_8)
    end
  end
end
