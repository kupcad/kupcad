// What the core gives the panels, for the tests: the real module's schema of a script and its
// preview.

export { modelOf, schemaOf } from '@kupcad/wasm/testing';

/** A script with a parameter of each kind, in groups. */
export const BRACKET = `# @title Bracket
# @description A plate with holes
w = param(:width, default: 20, validate: { min: 10, max: 100 }, unit: "mm", group: "Size")
h = param(:height, default: 5, step: 0.5, validate: { min: 1 }, group: "Size", title: "Height", description: "The plate's thickness")
hollow = param(:hollow, default: false)
label = param(:label, default: "A")
size = param(:size, default: :m4, validate: { in: [:m3, :m4, :m5] }, group: "Holes")
cube([w, 10, h])
`;

/** A plate and two copies of a red bolt. */
export const PARTS = `bolt = cylinder(r: 2, h: 5).named("bolt").material(color: "#cc3333")
[cube([20, 10, 2]).named("plate"), bolt.translate(x: 3, y: 5, z: 2), bolt.translate(x: 15, y: 5, z: 2)]
`;
