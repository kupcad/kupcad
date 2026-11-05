// What the native side keeps a copy of, which Rust can't read from @kupcad/protocol: each held
// to the protocol's. (An export's arguments are held by both hosts' tests to the protocol's
// fixture, build-arguments.json.)

import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { DEFAULT_MEMORY_LIMIT_GB, EXPORT_FORMATS, memoryLimitOf } from '@kupcad/protocol';
import { expect, it } from 'vitest';

it("the native side's list of formats is the protocol's", () => {
  // From the package's folder, where its tests run (the page's tests have no file URLs)
  const rust = readFileSync(resolve('src-tauri/src/export.rs'), 'utf8');
  const listed = /const FORMATS: \[&str; (\d+)\] = \[([^\]]*)\];/.exec(rust);
  if (!listed) throw new Error('export.rs declares no FORMATS');
  const formats = listed[2].match(/"([a-z0-9]+)"/g)?.map((quoted) => quoted.slice(1, -1));
  expect(Number(listed[1])).toBe(EXPORT_FORMATS.length);
  expect(formats).toEqual(EXPORT_FORMATS.map((choice) => choice.format));
});

it("the native side's largest memory limit is the protocol's", () => {
  // lib.rs keeps it as the page's setting has it: a limit the setting takes the native side
  // takes, and the next it refuses, as the setting does
  const rust = readFileSync(resolve('src-tauri/src/lib.rs'), 'utf8');
  const most = /const MAX_MEMORY_LIMIT_GB: u32 = ([\d *]+);/.exec(rust)?.[1];
  if (!most) throw new Error('lib.rs declares no MAX_MEMORY_LIMIT_GB');
  const gigabytes = most.split('*').reduce((product, factor) => product * Number(factor), 1);
  expect(memoryLimitOf(gigabytes)).toBe(gigabytes);
  expect(memoryLimitOf(gigabytes + 1)).toBe(DEFAULT_MEMORY_LIMIT_GB);
});
