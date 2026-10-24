// Models as the core makes them, for the tests: previews of scripts by the real module.

import { createKupcad } from '@kupcad/wasm';

/** @import { Model } from '@kupcad/protocol/types' */

/** @type {Promise<import('@kupcad/wasm').Kupcad> | null} */
let core = null;

const start = () => createKupcad({ log: () => {} });

/**
 * The model the core's preview of `source` shows.
 * @param {string} source
 * @returns {Promise<Model>}
 */
export async function modelOf(source) {
  core ??= start();
  const { header, model } = await (await core).preview(source);
  if (header.error) throw new Error(`the test's script failed: ${header.error.message}`);
  return model;
}

/**
 * A model built with Draco-compressed meshes.
 * @param {string} source
 * @returns {Promise<Model>}
 */
export async function dracoModelOf(source) {
  core ??= start();
  const glb = await (await core).build(source, { format: 'glb', draco: true });
  return { kind: '3d', glb, parts: [] };
}

/** A plate and two copies of a red bolt, beside a ghost. */
export const PARTS_WITH_GHOST = `bolt = cylinder(r: 2, h: 5).named("bolt").material(color: "#cc3333")
cube(10).translate(z: 1).ghost
[cube([20, 10, 2]).named("plate"), bolt.translate(x: 3, y: 5, z: 2), bolt.translate(x: 15, y: 5, z: 2)]
`;
