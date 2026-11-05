import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import {
  anotherDocument,
  DEFAULT_MEMORY_LIMIT_GB,
  memoryLimitOf,
  memoryLimitOptions,
  paramOptions,
  paramText,
  ScriptValues,
  viewportUrl,
} from './host.js';

/** An export's arguments, which the hosts' tests hold too (the desktop's native side's). */
const BUILD = JSON.parse(
  readFileSync(new URL('./fixtures/build-arguments.json', import.meta.url), 'utf8'),
);

describe('host', () => {
  it('writes values as kupcad build takes them: an array or an object as JSON', () => {
    const values = {
      w: 40,
      label: 'Gear A',
      on: false,
      holes: [
        [0, 0],
        [10, 0],
      ],
      at: { x: 1 },
    };
    expect(paramOptions(values)).toEqual([
      '-p',
      'w=40',
      '-p',
      'label=Gear A',
      '-p',
      'on=false',
      '-p',
      'holes=[[0,0],[10,0]]',
      '-p',
      'at={"x":1}',
    ]);
  });

  it("refuses a name kupcad would read as something else, as the desktop's native side does", () => {
    for (const name of BUILD.refusedNames) {
      expect(() => paramOptions({ [name]: 1 })).toThrow(`'${name}' is no parameter's name`);
    }
  });

  it("gives an export's values as the fixture the hosts hold has them", () => {
    // The desktop app's page gives its native side each value's text (paramText)
    expect(Object.entries(BUILD.values).map(([name, value]) => [name, paramText(value)])).toEqual(
      BUILD.params,
    );
    expect(paramOptions(BUILD.values)).toEqual(
      BUILD.params.flatMap((/** @type {[string, string]} */ [name, text]) => [
        '-p',
        `${name}=${text}`,
      ]),
    );
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
    expect(anotherDocument({ type: 'export', uri: shown.uri, format: 'stl' }, shown)).toBeNull();
    expect(
      anotherDocument({ type: 'export', uri: 'file:///w/other.kup', format: 'stl' }, shown),
    ).toBe('file:///w/other.kup');
    expect(anotherDocument({ type: 'export', uri: shown.uri, format: 'stl' }, null)).toBe(
      shown.uri,
    );
  });

  it("keeps each script's values, none for one given none", () => {
    const values = new ScriptValues();
    expect(values.of('file:///a.kup')).toEqual({});
    expect(values.has('file:///a.kup')).toBe(false);
    values.set('file:///a.kup', { width: 4 });
    expect(values.of('file:///a.kup')).toEqual({ width: 4 });
    expect([...values.entries()]).toEqual([['file:///a.kup', { width: 4 }]]);
  });

  it('limits the memory of a script it runs as kupcad reads the flag, the default for any other value', () => {
    expect(memoryLimitOptions(8)).toEqual(['--memory-limit', '8GB']);
    expect(memoryLimitOptions(64)).toEqual(['--memory-limit', '64GB']);
    // kupcad refuses these, and a server given one wouldn't start
    for (const wrong of [0, -1, 1.5, Number.NaN, Infinity, 1e30, '16', null, undefined]) {
      expect(memoryLimitOf(wrong)).toBe(DEFAULT_MEMORY_LIMIT_GB);
      expect(memoryLimitOptions(wrong)).toEqual(['--memory-limit', `${DEFAULT_MEMORY_LIMIT_GB}GB`]);
    }
    expect(memoryLimitOf(1024 * 1024)).toBe(1024 * 1024);
  });
});
