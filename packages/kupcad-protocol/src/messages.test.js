import { describe, expect, it } from 'vitest';
import { isHostMessage, isParamValues, isViewerMessage } from './index.js';

describe('isHostMessage', () => {
  it('takes the messages a host sends, field for field', () => {
    for (const message of [
      { type: 'document', document: { uri: 'file:///w/a.kup', name: 'a.kup' } },
      { type: 'document', document: null },
      { type: 'overrides', uri: 'file:///w/a.kup', values: { w: 3, label: 'A', hollow: true } },
      { type: 'presets', uri: 'file:///w/a.kup', names: ['Small', 'Large'] },
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
      { type: 'overrides', uri: 'file:///w/a.kup', values: { w: [3] } },
      { type: 'overrides', values: {} },
      { type: 'presets', uri: 'file:///w/a.kup', names: ['Small', 2] },
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
    expect(isViewerMessage({ type: 'export', uri: 'file:///w/a.kup' })).toBe(true);
    expect(isViewerMessage({ type: 'setParams', uri: 'file:///w/a.kup', values: null })).toBe(
      false,
    );
    expect(isViewerMessage({ type: 'screenshot', png: new Uint8Array() })).toBe(false);
    expect(isViewerMessage({ type: 'document', document: null })).toBe(false);
  });
});

it('reads parameter values as names to a number, a string or a boolean', () => {
  expect(isParamValues({})).toBe(true);
  expect(isParamValues({ w: 1, s: 'm4', b: false })).toBe(true);
  expect(isParamValues({ w: null })).toBe(false);
  expect(isParamValues({ w: {} })).toBe(false);
  expect(isParamValues([1])).toBe(false);
});
