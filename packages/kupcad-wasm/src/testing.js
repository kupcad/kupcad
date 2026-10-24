// For the tests of a package that shows what the core makes: the real module, made once a test
// process and silent, and what it gives of a script. A script that fails fails the test.

import { createKupcad } from './kupcad.js';

/** @import { Model, UiSchema } from '@kupcad/protocol/types' */
/** @import { Kupcad } from './kupcad.js' */

/** @type {Promise<Kupcad> | null} */
let core = null;

/**
 * The core, made on first use, its log dropped.
 * @returns {Promise<Kupcad>}
 */
export function testCore() {
  core ??= createKupcad({ log: () => {} });
  return core;
}

/**
 * The model the core's preview of `source` shows.
 * @param {string} source
 * @returns {Promise<Model>}
 */
export async function modelOf(source) {
  const { header, model } = await (await testCore()).preview(source);
  if (header.error) throw new Error(`the test's script failed: ${header.error.message}`);
  return model;
}

/**
 * The schema of `source`'s parameters.
 * @param {string} source
 * @returns {Promise<UiSchema>}
 */
export async function schemaOf(source) {
  return (await testCore()).params(source);
}
