import { expect, it } from 'vitest';
import { modelOf, schemaOf, testCore } from './testing.js';

it('gives the tests one core, the model of a script, and its schema', async () => {
  expect(testCore()).toBe(testCore());
  expect((await modelOf('cube(1)')).kind).toBe('3d');
  expect((await schemaOf('w = param(:w, default: 2)')).parameters[0].name).toBe('w');
});

it('fails the test of a script that fails, saying why', async () => {
  await expect(modelOf('raise "boom"')).rejects.toThrow(
    "the test's script failed: RuntimeError: boom",
  );
});
