import { describe, expect, it } from 'vitest';
import { PresetsError, presetsPathOf, readPresets, writePresets } from './presets.js';

describe('presets', () => {
  it('are kept beside their script, under its name', () => {
    expect(presetsPathOf('/work/bracket.kup')).toBe('/work/bracket.presets.json');
    expect(presetsPathOf('/work/parts/lid')).toBe('/work/parts/lid.presets.json');
  });

  it('read back as they were written, in their order', () => {
    const presets = { Small: { width: 20, hollow: false }, Large: { width: 80, label: 'L' } };
    const text = writePresets(presets);
    expect(text).toBe(
      `{\n  "presets": {\n    "Small": {\n      "width": 20,\n      "hollow": false\n    },\n    "Large": {\n      "width": 80,\n      "label": "L"\n    }\n  }\n}\n`,
    );
    expect(Object.keys(readPresets(text))).toEqual(['Small', 'Large']);
    expect(readPresets(text)).toEqual(presets);
  });

  it("say what is wrong with a file that isn't presets", () => {
    expect(() => readPresets('{')).toThrow(PresetsError);
    expect(() => readPresets('{"presets": []}')).toThrow('it has no "presets" object');
    expect(() => readPresets('{"Small": {}}')).toThrow('it has no "presets" object');
    expect(() => readPresets('{"presets": {"Small": {"width": {"a": 1}}}}')).toThrow(
      'its preset "Small" isn\'t values by name',
    );
  });
});
