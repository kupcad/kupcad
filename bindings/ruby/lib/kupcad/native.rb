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
      raise LoadError, "#{path} not found: this kupcad came without libkupcad, which only a platform gem carries " \
                       "(this is #{RUBY_PLATFORM}). Set KUPCAD_LIBRARY to a libkupcad you built (`zig build lib` in " \
                       "the kupcad repository's core/), or run the kupcad CLI."
    end

    # ffi opens a library on Windows with LoadLibraryExA, which reads the path in the system's
    # code page, not as the UTF-8 Ruby gives it: a path past ASCII (C:\Users\José\...) wasn't
    # found. There the library is loaded by its path in UTF-16 first, as ffi loads one by its
    # path (its own folder searched for what it needs), then ffi opens it by its file name, which
    # Windows resolves to the module of that name already loaded, searching no folder.
    if FFI::Platform.windows?
      # Windows' loader, which takes a path in UTF-16
      module Kernel32
        extend FFI::Library

        ffi_lib 'kernel32'
        ffi_convention :stdcall

        LOAD_WITH_ALTERED_SEARCH_PATH = 0x8

        attach_function :LoadLibraryExW, %i[buffer_in pointer uint32], :pointer
      end
      private_constant :Kernel32

      wide = "#{File.expand_path(path).tr('/', '\\')}\0".encode(Encoding::UTF_16LE)
      if Kernel32.LoadLibraryExW(wide, nil, Kernel32::LOAD_WITH_ALTERED_SEARCH_PATH).null?
        raise LoadError, "#{path} can't be loaded: Windows error #{FFI::LastError.winapi_error}"
      end

      ffi_lib File.basename(path)
    else
      ffi_lib path
    end

    # First, so a library of another ABI is refused as one, not for a function it lacks
    attach_function :kupcad_abi_version, [], :uint32
    abi = kupcad_abi_version
    unless abi == ABI_VERSION
      raise LoadError, "#{path} is libkupcad of ABI #{abi}; this gem speaks ABI #{ABI_VERSION}: use the libkupcad " \
                       "of KupCAD #{VERSION}"
    end

    enum :status, [:ok, 0, :script_error, :invalid_argument, :out_of_memory, :internal_error]

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

    module_function

    # The bytes, in native memory a blocking call may read with the GVL released, and their
    # length; nil for none
    def buffer(bytes)
      return [nil, 0] if bytes.empty?

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
