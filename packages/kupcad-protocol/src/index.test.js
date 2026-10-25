import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import {
  isCompatible,
  PROTOCOL_VERSION,
  ProtocolError,
  readFrame,
  SET_PARAMS_COMMAND,
  PREVIEW_COMMAND,
  VIEWPORT_READY_NOTIFICATION,
} from './index.js';
// Headers the core's preview worker sent (their timings made fixed)
import solid from './fixtures/solid.json' with { type: 'json' };
import sketch from './fixtures/sketch.json' with { type: 'json' };
import refused from './fixtures/refused.json' with { type: 'json' };

/**
 * A frame as the core writes it: the header's length (u32, little-endian), the header, the body.
 * @param {unknown} header
 * @param {Uint8Array} [body]
 * @returns {Uint8Array}
 */
function frameOf(header, body = new Uint8Array()) {
  const json = new TextEncoder().encode(
    typeof header === 'string' ? header : JSON.stringify(header),
  );
  const bytes = new Uint8Array(4 + json.byteLength + body.byteLength);
  new DataView(bytes.buffer).setUint32(0, json.byteLength, true);
  bytes.set(json, 4);
  bytes.set(body, 4 + json.byteLength);
  return bytes;
}

/**
 * A core source file's text, by its path under core/src.
 * @param {string} path
 */
const coreSource = (path) =>
  readFileSync(new URL(`../../../core/src/${path}`, import.meta.url), 'utf8');

const GLB = new TextEncoder().encode('glTF\x02\x00\x00\x00 the model');
const SVG = '<svg xmlns="http://www.w3.org/2000/svg"><path id="plate" d="M0 0Z"/></svg>';

describe('readFrame', () => {
  it("reads a 3D frame: the header as the core writes it, the GLB a view on the frame's bytes", () => {
    const bytes = frameOf(solid, GLB);
    const { header, model } = readFrame(bytes);
    expect(header).toEqual(solid);
    expect(header.document).toBe('file:///work/solid.kup');
    expect(header.params.values).toEqual({ width: 25 });
    expect(header.params.schema.parameters[0]).toMatchObject({
      name: 'width',
      unit: 'mm',
      group: 'Size',
      title: 'Width',
      description: null,
    });
    if (model.kind !== '3d') throw new Error(`a ${model.kind} model`);
    expect(model.glb).toEqual(GLB);
    expect(model.glb.buffer).toBe(bytes.buffer);
    expect(model.parts.map((p) => p.nodes)).toEqual([['plate'], ['bolt', 'bolt_2']]);
    expect(model.parts[1].color).toBe('#cc3333');
  });

  it("reads a 2D frame's body as its SVG", () => {
    const { model } = readFrame(frameOf(sketch, new TextEncoder().encode(SVG)));
    expect(model).toEqual({ kind: '2d', svg: SVG });
  });

  it('reads a failed run: no model, and why, where, and the parameter refused', () => {
    const { header, model } = readFrame(frameOf(refused));
    expect(model).toEqual({ kind: 'none' });
    expect(header.error).toEqual({
      message: 'ValueError: parameter :width value 5 is below its minimum 10',
      // The `param` call that refused it
      line: 1,
      column: 5,
      param: 'width',
    });
  });

  it('reads an ArrayBuffer, and a Uint8Array that views part of a larger buffer', () => {
    const bytes = frameOf(solid, GLB);
    expect(readFrame(bytes.slice().buffer).model.kind).toBe('3d');
    const larger = new Uint8Array(bytes.byteLength + 8);
    larger.set(bytes, 3);
    const { model } = readFrame(larger.subarray(3, 3 + bytes.byteLength));
    if (model.kind !== '3d') throw new Error(`a ${model.kind} model`);
    expect(model.glb).toEqual(GLB);
  });

  it('refuses a frame cut short, a header that is no JSON object, and an unknown kind', () => {
    const refusals = [
      new Uint8Array([2, 0]),
      frameOf(solid).subarray(0, 20),
      frameOf('{"protocolVersion": 1,'),
      frameOf('[1]'),
      frameOf({ ...solid, kind: '4d' }),
    ];
    for (const bytes of refusals) expect(() => readFrame(bytes)).toThrow(ProtocolError);
  });

  it('refuses a frame of another protocol version, saying which', () => {
    const later = { ...solid, protocolVersion: PROTOCOL_VERSION + 1 };
    expect(() => readFrame(frameOf(later))).toThrow(`protocol version ${PROTOCOL_VERSION + 1}`);
  });
});

describe('the protocol', () => {
  it('reads its own version only', () => {
    expect(isCompatible(PROTOCOL_VERSION)).toBe(true);
    expect(isCompatible(PROTOCOL_VERSION + 1)).toBe(false);
    expect(isCompatible(String(PROTOCOL_VERSION))).toBe(false);
  });

  it("is the core's: its version and its names are the ones the core's sources declare", () => {
    expect(coreSource('preview/frame.zig')).toContain(
      `pub const PROTOCOL_VERSION: u32 = ${PROTOCOL_VERSION};`,
    );
    const lsp = coreSource('cli/lsp.zig');
    expect(lsp).toContain(
      `pub const VIEWPORT_READY_NOTIFICATION = "${VIEWPORT_READY_NOTIFICATION}";`,
    );
    expect(lsp).toContain(`pub const SET_PARAMS_COMMAND = "${SET_PARAMS_COMMAND}";`);
    expect(lsp).toContain(`pub const PREVIEW_COMMAND = "${PREVIEW_COMMAND}";`);
  });
});
