# KupCAD for Ruby

Builds the model of a [KupCAD](https://kupcad.org) script, with its parameters, as STL, 3MF,
glTF, OBJ, STEP, SVG or DXF, and formats, lints and reads the parameters of scripts. It runs
libkupcad, the KupCAD core as a C library, in your process: nothing to install besides the gem.

```sh
gem install kupcad
```

```ruby
require 'kupcad'

source = File.read('bracket.kup')
model = Kupcad.build(source, format: :stl, params: { width: 60, label: 'A' })
File.binwrite('bracket.stl', model.data)
puts model.report.output        # what the script printed
model.report.warnings.each { |w| warn "#{w.line}: #{w.message}" }
```

## What it does

- `Kupcad.build(source, format:, params:, files:, memory_limit:, timeout:, draco:)` runs the
  script and returns a `Kupcad::Model`: its `data` (binary) in the `format` (one of
  `Kupcad::FORMATS`, the library's: `:stl`, `:"3mf"`, `:glb`, `:gltf`, `:obj`, `:step`, `:svg`,
  `:dxf`), and the run's `report`, what the script printed and the `Kupcad::RunWarning`s it
  warned of, where.
  - `params:` the parameters' values by name, as `kupcad build -p` takes them:
    `{ width: 60, thread: :m4, holes: [[5, 5], [35, 5]] }`, each what JSON has a type for (a
    String or a Symbol, an Integer or a Float, true, false, nil, an Array or a Hash of them).
    Values are checked against each parameter's rules.
  - `files:` the files the script imports, by their path from its folder, each a String, text
    or binary: `{ 'lib/gears.kup' => File.read('lib/gears.kup'), 'parts/base.stl' =>
    File.binread(...) }`. A script reads no other file, and its exports (`export_stl`) write
    nothing.
  - `nil` for `params:` or `files:` is none, as leaving them out is.
  - `memory_limit:` the most memory, in bytes, the script may hold: its values and its
    geometry graph, not the kernel's meshes; no limit by default.
  - `timeout:` the most time, in seconds, the build may take, to the millisecond; no limit by
    default (or `Float::INFINITY`). A script that never ends otherwise holds its thread for
    good: a native call can't be interrupted, by `Timeout` or by Ctrl-C, which are raised once
    it returns.
  - `draco: true` compresses a GLB's or a glTF's meshes.
- `Kupcad.format(source)`: the source as `kupcad fmt` formats it.
- `Kupcad.check(source)`: what `kupcad check` finds, an Array of `Kupcad::Finding` (severity,
  rule, message, where, and the fix if there is one). Syntax errors are findings here.
- `Kupcad.params(source)`: the parameters the script declares and its metadata, the schema
  `kupcad doc` prints, to build a form from.
- `Kupcad.library_version`: the version of libkupcad loaded.

A source, and a file's path, is read in the encoding the String says it is in (a binary or
US-ASCII one as UTF-8, which is what libkupcad reads); a file's content is passed as its bytes.

## Errors

- `Kupcad::ScriptError` (a `Kupcad::Error`) when the script doesn't parse or compile, raises,
  runs past its `timeout` or `memory_limit`, or leaves no model. A value one of its parameters
  refuses is one too: the script raises `ValueError` at the `param` that refuses it. The
  message says where and why (`"2:5: Invalid expression ..."`, `"RuntimeError: Plate too
  thin"`), and its `report` holds what the script printed until then.
- `ArgumentError` for a format that isn't one, a limit that isn't positive, parameter values
  JSON can't hold (NaN), or values that aren't by name (an Array).
- `TypeError` for parameter values JSON has no type for (a `Rational`, a `BigDecimal`, a `Set`:
  JSON would write them as text), saying which, or a source, or a file's content, that isn't a
  String (a `Pathname`: read it).
- `NoMemoryError` when the process itself runs out of memory, and `Kupcad::Error` itself when
  libkupcad fails on its own, a bug of KupCAD's.

## Threads and processes

A build releases the GVL while it runs, so other threads go on, and builds on several threads
run at once: libkupcad's calls share nothing. A process may fork between builds (Puma's or
Unicorn's `preload_app`), whatever threads built before: the last build to end ends the worker
threads the builds started, and each process starts its own; but not while a build runs on
another thread. The core runs in your process, so a bug it stops on stops the process too.
To run scripts you don't trust, or keep a crash away from a web server, run the
[`kupcad` CLI](https://docs.kupcad.org/reference/tooling/cli/) as a process of its own.

## Platforms

Each platform gem carries its libkupcad: Linux (x86_64, aarch64; glibc 2.28 or later), macOS
(arm64, x86_64) and Windows (x64, aarch64), with `THIRD_PARTY_NOTICES.md` and the license texts
of what it is built from beside it, in `lib/kupcad/native/`. Elsewhere (musl, BSD), build
libkupcad with `zig build lib` in the kupcad repository's `core/`, install the gem from
`bindings/ruby/` (`gem build kupcad.gemspec && gem install kupcad-*.gem`, a gem without the
library) and point `KUPCAD_LIBRARY` at the library.

## Development

In the kupcad repository:

```sh
(cd core && zig build lib -Doptimize=safe)   # core/zig-out/lib/libkupcad.*
cd bindings/ruby
bundle install
bundle exec rake                             # specs, RuboCop, RBS
```

The specs load the checkout's library (`KUPCAD_LIBRARY` names another). `rake native:gem
PLATFORM=arm64-darwin LIBRARY=path/libkupcad.dylib` packs a platform gem around a library built
for it, as the release does, with the notices `core/scripts/collect-licenses.sh <the library's
folder>` (run from the repository root) puts beside it.
