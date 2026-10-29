# @kupcad/wasm

The KupCAD core compiled to WebAssembly: preview, build, check, format and read the parameters of
a script, in a page or in Node, with no server. The shapes it gives back are
[@kupcad/protocol](../kupcad-protocol)'s.

```js
import { createKupcadWorker } from '@kupcad/wasm';

const kupcad = createKupcadWorker(); // the core in a Web Worker: a long build doesn't freeze the page

const { header, model } = await kupcad.preview(source, { params: { width: 40 } });
// model: { kind: '3d', glb, parts } | { kind: '2d', svg } | { kind: 'none' }
// header.error: why the run failed, where, and the parameter whose value was refused

const stl = await kupcad.build(source, { format: 'stl' }); // Uint8Array
const findings = await kupcad.check(source);
const formatted = await kupcad.format(source);
const schema = await kupcad.params(source); // the parameter panel's controls, without a run
// The files the script reads, by the paths it names: a module it imports, data (an STL, a JSON)
await kupcad.build(source, { files: { 'lib.kup': libSource, 'plate.dxf': bytes } });
```

## In a worker, or in this thread

* `createKupcadWorker(options)` runs the core in a module Web Worker. Calls run one at a time,
  the next waiting its turn. A call's `signal` (an `AbortSignal`) drops it while it waits, and
  stops the worker while it runs: a script can't be stopped inside the module, so the worker is
  ended and a new one starts with the next call. A worker whose core stopped (a trap) is replaced
  the same way. A
  call that can't be sent (the worker doesn't start, or its arguments can't be posted to one) is
  refused with why, and the next goes. `terminate()` ends it for good.
* `createKupcad(options)` instantiates the core in this thread: the same calls, for Node, tests
  and a worker of the host's own. `Kupcad.fromExports(exports)` takes a module the host
  instantiated itself.

Both take `wasm` (the module: a URL, its bytes or a compiled `WebAssembly.Module`, and for
`createKupcad` a fetch `Response` too, which can't be posted to a worker; by default the
`kupcad.wasm` this package ships) and `log` (where the module's log goes, a line at a time; by
default `console.debug`). A worker is given a relative URL resolved against the page, as the
page means it. The worker is always handed its module, this package's by default: only the
page's side names the shipped `kupcad.wasm` (`src/create.js`), so a site's bundler, which copies
the file for each bundle that names it, ships it once rather than once more for the worker.

## What a call can fail with

* `KupcadError`: the core refused, with its message: a script that doesn't parse
  (`1:6: Expected 'r_paren' ...`) or run (`RuntimeError: boom`), values it refused
  (`parameters: ...`), a format it doesn't write. A preview doesn't throw for these: its frame
  says why.
* `KupcadCrashError`: the module stopped (a trap, or an exit), or the worker failed (its script
  didn't load, or it sent what couldn't be read). A worker is replaced on the next call; a module
  of `createKupcad` is made again.
* `ProtocolError` (@kupcad/protocol's): the module speaks a protocol version this package doesn't
  read.

## Inside

The module asks its host for WASI. A browser has none and Node's would give it a file system, so
the package answers it itself (`src/wasi.js`): the host's clocks and randomness, the log, and no
files. A script reads the files its call brings (`files`, by the paths the script names them):
they are packed into one buffer (`src/files.js`, as `core/src/vfs/packed.zig` reads it) and
kept in an in-memory file system of that call alone, so no script sees another's files and a
script's exports go nowhere. A build runs under the core's interactive limits (instructions,
memory), as a preview does: a runaway script stops with an error instead of hanging the worker. Every string and buffer is copied in and freed after the call;
every result is copied out and freed. `pnpm build` copies the module from the core's
build (`pnpm build:core:wasm` at the root) into `dist/`, which the package ships; its version is
the core's, which the tests hold it to.

The threaded build of the core (`-Dwasm_threads`) isn't shipped yet: it needs a host that runs
its threads in workers and pages served cross-origin isolated.

`@kupcad/wasm/types` has the API's types (`KupcadApi`, the options, the worker's messages).
`@kupcad/wasm/testing` is for the tests of a package that shows what the core makes: the real
module, made once a test process (`testCore`), and `modelOf` and `schemaOf` of a script, a
script that fails failing the test.
