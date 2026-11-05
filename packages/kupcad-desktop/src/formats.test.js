import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { EXPORT_FORMATS } from '@kupcad/protocol';
import { expect, it } from 'vitest';

it("the native side's list of formats is the protocol's", () => {
  // Rust can't read the protocol's table: export.rs keeps a copy, which this holds to it
  // From the package's folder, where its tests run (the page's tests have no file URLs)
  const rust = readFileSync(resolve('src-tauri/src/export.rs'), 'utf8');
  const listed = /const FORMATS: \[&str; (\d+)\] = \[([^\]]*)\];/.exec(rust);
  if (!listed) throw new Error('export.rs declares no FORMATS');
  const formats = listed[2].match(/"([a-z0-9]+)"/g)?.map((quoted) => quoted.slice(1, -1));
  expect(Number(listed[1])).toBe(EXPORT_FORMATS.length);
  expect(formats).toEqual(EXPORT_FORMATS.map((choice) => choice.format));
});
