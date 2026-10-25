import { describe, expect, it } from 'vitest';
import { anotherDocument, paramOptions, ScriptValues, viewportUrl } from './host.js';

describe('host', () => {
  it('writes values as kupcad build takes them: an array as JSON', () => {
    expect(
      paramOptions({
        w: 40,
        label: 'Gear A',
        on: false,
        holes: [
          [0, 0],
          [10, 0],
        ],
      }),
    ).toEqual(['-p', 'w=40', '-p', 'label=Gear A', '-p', 'on=false', '-p', 'holes=[[0,0],[10,0]]']);
  });

  it("reads the viewport socket's URL from a port, and none from what is no port", () => {
    expect(viewportUrl(9001)).toBe('ws://127.0.0.1:9001');
    // The app used whatever came: ws://127.0.0.1:undefined
    for (const port of [0, -1, 65536, 9001.5, '9001', null, undefined])
      expect(viewportUrl(port)).toBeNull();
  });

  it('takes a message about the document shown, or about none, and no other', () => {
    const shown = { uri: 'file:///w/part.kup', name: 'part.kup' };
    expect(anotherDocument({ type: 'ready' }, shown)).toBeNull();
    expect(anotherDocument({ type: 'export', uri: shown.uri }, shown)).toBeNull();
    expect(anotherDocument({ type: 'export', uri: 'file:///w/other.kup' }, shown)).toBe(
      'file:///w/other.kup',
    );
    expect(anotherDocument({ type: 'export', uri: shown.uri }, null)).toBe(shown.uri);
  });

  it("keeps each script's values, none for one given none", () => {
    const values = new ScriptValues();
    expect(values.of('file:///a.kup')).toEqual({});
    expect(values.has('file:///a.kup')).toBe(false);
    values.set('file:///a.kup', { width: 4 });
    expect(values.of('file:///a.kup')).toEqual({ width: 4 });
    expect([...values.entries()]).toEqual([['file:///a.kup', { width: 4 }]]);
  });
});
