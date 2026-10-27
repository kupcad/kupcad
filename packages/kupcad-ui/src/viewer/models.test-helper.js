// Models as the core makes them, for the tests: previews of scripts by the real module.

import { testCore } from '@kupcad/wasm/testing';

/** @import { Model } from '@kupcad/protocol/types' */

export { modelOf } from '@kupcad/wasm/testing';

/**
 * A model built with Draco-compressed meshes.
 * @param {string} source
 * @returns {Promise<Model>}
 */
export async function dracoModelOf(source) {
  const glb = await (await testCore()).build(source, { format: 'glb', draco: true });
  return { kind: '3d', glb, parts: [] };
}

/** A box, and a pin inside it the script highlights. */
export const HIGHLIGHTED_PIN = `[cube(10).named("box"), cube(2).translate(x: 4, y: 4, z: 4).named("pin").highlight]
`;

/** A plate and two copies of a red bolt, beside a ghost. */
export const PARTS_WITH_GHOST = `bolt = cylinder(r: 2, h: 5).named("bolt").material(color: "#cc3333")
cube(10).translate(z: 1).ghost
[cube([20, 10, 2]).named("plate"), bolt.translate(x: 3, y: 5, z: 2), bolt.translate(x: 15, y: 5, z: 2)]
`;
