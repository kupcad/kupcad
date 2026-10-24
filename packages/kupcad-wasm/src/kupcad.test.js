import { existsSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { beforeAll, describe, expect, it } from 'vitest';
import { PROTOCOL_VERSION, ProtocolError } from '@kupcad/protocol';
import { createKupcad, Kupcad, KupcadCrashError, KupcadError } from './index.js';
import { WasiExit } from './wasi.js';

/** @import { KupcadExports } from './types.js' */

const SHIPPED = new URL('../dist/kupcad.wasm', import.meta.url);
const PACKAGE = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
const decoder = new TextDecoder();

/** @type {Kupcad} */
let kupcad;
/** @type {string[]} */
const logged = [];

beforeAll(async () => {
  if (!existsSync(SHIPPED)) {
    throw new Error(
      `${fileURLToPath(SHIPPED)} is missing: \`pnpm build:core:wasm\`, then \`pnpm --filter @kupcad/wasm build\``,
    );
  }
  kupcad = await createKupcad({ log: (line) => logged.push(line) });
});

describe('createKupcad', () => {
  it("instantiates the module this package ships, the core's version, speaking this protocol", async () => {
    expect(await kupcad.version()).toEqual({
      version: PACKAGE.version,
      protocolVersion: PROTOCOL_VERSION,
      os: 'wasi',
      arch: 'wasm32',
    });
    const zon = readFileSync(new URL('../../../core/build.zig.zon', import.meta.url), 'utf8');
    expect(zon).toContain(`.version = "${PACKAGE.version}"`);
  });

  it('takes the module as bytes, compiled, or by URL', async () => {
    const bytes = readFileSync(SHIPPED);
    const compiled = await WebAssembly.compile(bytes);
    for (const wasm of [bytes, compiled, SHIPPED, SHIPPED.href]) {
      const made = await createKupcad({ wasm, log: () => {} });
      expect((await made.version()).arch).toBe('wasm32');
    }
  });
});

describe('preview', () => {
  it('gives the frame: the model, its parts and the values the run took', async () => {
    const { header, model } = await kupcad.preview(
      'w = param(:width, default: 2)\ncube(w).named("block")',
      { params: { width: 3 } },
    );
    expect(header.document).toBeNull();
    expect(header.params.values).toEqual({ width: 3 });
    if (model.kind !== '3d') throw new Error(`a ${model.kind} model`);
    expect(decoder.decode(model.glb.subarray(0, 4))).toBe('glTF');
    expect(model.parts.map((part) => part.name)).toEqual(['block']);
  });

  it('gives a failed run, and values the core refuses, as a frame saying why', async () => {
    const failed = await kupcad.preview('cube(1)\nraise "boom"');
    expect(failed.model).toEqual({ kind: 'none' });
    expect(failed.header.error).toMatchObject({ message: 'RuntimeError: boom', line: 2 });
    const refused = await kupcad.preview('cube(2)', { params: { w: /** @type {any} */ ([1]) } });
    expect(refused.header.error?.message).toMatch(/^parameters: parameter 'w' is an array/);
  });

  it('gives a Sketch as SVG', async () => {
    const { model } = await kupcad.preview('square(10).named("plate")');
    if (model.kind !== '2d') throw new Error(`a ${model.kind} model`);
    expect(model.svg).toContain('id="plate"');
  });
});

describe('build', () => {
  it.each(
    /** @type {[import('@kupcad/protocol/types').ExportFormat, string][]} */ ([
      ['glb', 'glTF'],
      ['gltf', '{"asset"'],
      ['stl', 'KupCAD'],
      ['step', 'ISO-10303-21'],
      ['3mf', 'PK\x03\x04'],
      ['obj', '# KupCAD'],
      ['svg', '<?xml'],
      ['dxf', '0\nSECTION'],
    ]),
  )('writes the model as %s', async (format, start) => {
    const bytes = await kupcad.build('cube(2)', { format });
    expect(decoder.decode(bytes.subarray(0, start.length))).toBe(start);
  });

  it('writes GLB unless asked for another format', async () => {
    expect(decoder.decode((await kupcad.build('cube(2)')).subarray(0, 4))).toBe('glTF');
  });

  it("refuses with the core's message: a syntax error where it is, a runtime error, a bad format", async () => {
    await expect(kupcad.build('cube(')).rejects.toThrow(
      new KupcadError("1:6: Expected 'r_paren', but found '' [unexpected-token]"),
    );
    await expect(kupcad.build('raise "boom"')).rejects.toThrow(
      new KupcadError('RuntimeError: boom'),
    );
    await expect(kupcad.build('cube(1)', { format: /** @type {any} */ ('xyz') })).rejects.toThrow(
      new KupcadError('Unsupported Format'),
    );
    // The core's log has it too
    expect(logged).toContain('error(vm): RuntimeError: boom');
  });

  it('reads the files put, and not once they are cleared', async () => {
    const reads = 'cube(import_json("size.json")[:side])';
    await kupcad.files.put('size.json', '{"side": 3}');
    expect((await kupcad.build(reads, { format: 'stl' })).byteLength).toBeGreaterThan(84);
    await kupcad.files.put('size.json', new TextEncoder().encode('{"side": 4}'));
    await kupcad.files.clear();
    await expect(kupcad.build(reads)).rejects.toThrow(/could not read JSON file 'size.json'/);
  });
});

describe('check, format and params', () => {
  it("give check's findings, fmt's text and doc's schema", async () => {
    const [finding] = await kupcad.check('x = 1\ncube(');
    expect(finding).toMatchObject({
      line: 2,
      column: 6,
      offset: 11,
      severity: 'error',
      rule: null,
    });
    expect(await kupcad.format('x=1')).toBe('x = 1\n');
    await expect(kupcad.format('cube(')).rejects.toThrow(new KupcadError('Syntax Error'));
    const schema = await kupcad.params('w = param(:w, default: 2, unit: "mm")');
    expect(schema.parameters[0]).toMatchObject({
      name: 'w',
      type: 'number',
      default_value: 2,
      unit: 'mm',
    });
  });
});

it('a call whose signal is already aborted is refused, and the module goes on', async () => {
  const controller = new AbortController();
  controller.abort();
  await expect(kupcad.check('x = 1', { signal: controller.signal })).rejects.toThrow(/abort/i);
  expect(await kupcad.format('x=1')).toBe('x = 1\n');
});

it("frees what each call takes and gives: the module's memory stays where it was", async () => {
  const round = async () => {
    await kupcad.preview('cube(2)');
    await kupcad.build('cube(2)', { format: 'stl' });
    await kupcad.check('x = 1');
    await kupcad.format('x=1');
    await kupcad.build('raise "boom"').catch(() => {});
  };
  for (let i = 0; i < 3; i++) await round();
  const settled = kupcad.memoryBytes;
  for (let i = 0; i < 30; i++) await round();
  expect(kupcad.memoryBytes).toBe(settled);
});

/** A trap in the module, as a wasm `unreachable` raises one. */
const trap = () => {
  throw new WebAssembly.RuntimeError('unreachable');
};

/**
 * The exports of a module whose check traps.
 * @returns {KupcadExports}
 */
const trapping = () =>
  /** @type {KupcadExports} */ (
    /** @type {unknown} */ ({
      memory: new WebAssembly.Memory({ initial: 1 }),
      wasm_alloc: () => 8,
      wasm_free: () => {},
      check_code_wasm: trap,
      format_code_wasm: () => {
        throw new Error('not to be called once the module stopped');
      },
    })
  );

describe('a module that stops', () => {
  it('is a crash, for the call it stopped in and every call after', async () => {
    const stopped = new Kupcad(trapping());
    await expect(stopped.check('x')).rejects.toBeInstanceOf(KupcadCrashError);
    await expect(stopped.format('x')).rejects.toBeInstanceOf(KupcadCrashError);
  });

  it('by exiting (WASI proc_exit) is a crash too, saying how it exited', async () => {
    const exits = trapping();
    exits.check_code_wasm = () => {
      throw new WasiExit(3);
    };
    const stopped = new Kupcad(exits);
    await expect(stopped.check('x')).rejects.toThrow(
      new KupcadCrashError('kupcad.wasm stopped: kupcad.wasm exited with code 3'),
    );
    await expect(stopped.format('x')).rejects.toBeInstanceOf(KupcadCrashError);
  });
});

it('a module of another protocol version is refused', async () => {
  const memory = new WebAssembly.Memory({ initial: 1 });
  // Its version_wasm says it speaks the next version
  const json = new TextEncoder().encode(
    JSON.stringify({
      version: '9.0.0',
      protocolVersion: PROTOCOL_VERSION + 1,
      os: 'wasi',
      arch: 'wasm32',
    }),
  );
  const exports = /** @type {KupcadExports} */ (
    /** @type {unknown} */ ({
      memory,
      wasm_alloc: () => 16,
      wasm_free: () => {},
      version_wasm: (/** @type {number} */ outLen) => {
        new DataView(memory.buffer).setUint32(outLen, json.byteLength, true);
        new Uint8Array(memory.buffer, 64, json.byteLength).set(json);
        return 64;
      },
    })
  );
  await expect(Kupcad.fromExports(exports)).rejects.toThrow(
    new ProtocolError(
      `kupcad.wasm 9.0.0 speaks protocol version ${PROTOCOL_VERSION + 1}; this package reads version ${PROTOCOL_VERSION}`,
    ),
  );
});
