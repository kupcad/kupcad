/* HarfBuzz's configuration, after its presets (build.zig asks for HB_LEAN and HB_NO_AAT):
   HB_CONFIG_OVERRIDE_H names this file. HB_LEAN's HB_NO_ERRNO stands a static variable in for
   errno, which clashes with WASI libc's thread-local errno declared after it; the C library's
   errno is there on every target KupCAD builds for. */
#undef HB_NO_ERRNO
