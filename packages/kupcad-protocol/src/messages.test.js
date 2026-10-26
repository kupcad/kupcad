import { describe, expect, it } from 'vitest';
import { isHostMessage, isParamValues, isViewerMessage, MAX_PARAM_DEPTH } from './index.js';

describe('isHostMessage', () => {
  it('takes the messages a host sends, field for field', () => {
    for (const message of [
      { type: 'document', document: { uri: 'file:///w/a.kup', name: 'a.kup' } },
      { type: 'document', document: null },
      { type: 'overrides', uri: 'file:///w/a.kup', values: { w: 3, label: 'A', hollow: true } },
      { type: 'presets', uri: 'file:///w/a.kup', names: ['Small', 'Large'] },
      { type: 'log', text: 'info(session_manager): Initialized' },
    ]) {
      expect(isHostMessage(message)).toBe(true);
    }
  });

  it('refuses anything else: another type, a field missing or of another kind, a viewer message', () => {
    for (const message of [
      null,
      'document',
      [],
      { type: 'documents', document: null },
      { type: 'document' },
      { type: 'document', document: { uri: 'file:///w/a.kup' } },
      { type: 'overrides', uri: 'file:///w/a.kup', values: { w: [null] } },
      { type: 'overrides', values: {} },
      { type: 'presets', uri: 'file:///w/a.kup', names: ['Small', 2] },
      { type: 'log', text: 3 },
      { type: 'ready' },
      { type: 'toString' },
    ]) {
      expect(isHostMessage(message)).toBe(false);
    }
  });
});

describe('isViewerMessage', () => {
  it('takes the messages a viewer sends, and nothing of another shape', () => {
    expect(isViewerMessage({ type: 'ready' })).toBe(true);
    expect(isViewerMessage({ type: 'setParams', uri: 'file:///w/a.kup', values: {} })).toBe(true);
    expect(isViewerMessage({ type: 'screenshot', png: 'iVBORw0KGgo=' })).toBe(true);
    expect(isViewerMessage({ type: 'problem', message: 'the socket closed' })).toBe(true);
    expect(isViewerMessage({ type: 'applyPreset', uri: 'file:///w/a.kup', name: 'Small' })).toBe(
      true,
    );
    expect(isViewerMessage({ type: 'savePreset', uri: 'file:///w/a.kup', values: { w: 3 } })).toBe(
      true,
    );
    expect(isViewerMessage({ type: 'applyPreset', uri: 'file:///w/a.kup' })).toBe(false);
    expect(isViewerMessage({ type: 'export', uri: 'file:///w/a.kup', format: 'svg' })).toBe(true);
    // The format it is asked in, one the core writes
    expect(isViewerMessage({ type: 'export', uri: 'file:///w/a.kup' })).toBe(false);
    expect(isViewerMessage({ type: 'export', uri: 'file:///w/a.kup', format: 'pdf' })).toBe(false);
    expect(isViewerMessage({ type: 'reveal', uri: 'file:///w/a.kup', line: 3, column: 1 })).toBe(
      true,
    );
    // A place is a line and a column from 1
    for (const [line, column] of [
      [0, 1],
      [3, 0],
      [1.5, 1],
      [3, null],
    ]) {
      expect(isViewerMessage({ type: 'reveal', uri: 'file:///w/a.kup', line, column })).toBe(false);
    }
    expect(isViewerMessage({ type: 'setParams', uri: 'file:///w/a.kup', values: null })).toBe(
      false,
    );
    expect(isViewerMessage({ type: 'screenshot', png: new Uint8Array() })).toBe(false);
    expect(isViewerMessage({ type: 'document', document: null })).toBe(false);
  });
});

/**
 * Values whose one array is `depth` deep.
 * @param {number} depth
 */
function nested(depth) {
  /** @type {unknown} */
  let value = [];
  for (let i = 1; i < depth; i++) value = [value];
  return { w: value };
}

it('reads parameter values as names to a scalar, or an array or an object of them, two deep', () => {
  expect(isParamValues({})).toBe(true);
  expect(isParamValues({ w: 1, s: 'm4', b: false })).toBe(true);
  expect(
    isParamValues({
      size: [10, 20],
      holes: [
        [0, 0],
        [10, 'x', true],
      ],
      none: [],
    }),
  ).toBe(true);
  expect(isParamValues({ cuts: [{ type: 'slot', depth: 5 }], origin: { x: 0 }, w: {} })).toBe(true);
  expect(isParamValues({ w: { a: [1] } })).toBe(true);
  expect(isParamValues({ w: null })).toBe(false);
  expect(isParamValues({ w: [1, null] })).toBe(false);
  expect(isParamValues({ w: [{ a: [1] }] })).toBe(false);
  expect(isParamValues([1])).toBe(false);
  expect(isParamValues(nested(MAX_PARAM_DEPTH))).toBe(true);
  expect(isParamValues(nested(MAX_PARAM_DEPTH + 1))).toBe(false);
});
