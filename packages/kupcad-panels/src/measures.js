// What the viewer's tooltip says of what is under the pointer: a part's name, copies, volume and
// size, a face's area and the way it faces, in the model's millimetres.

/** @import { Part } from '@kupcad/protocol/types' */
/** @import { Face } from '@kupcad/viewer/types' */

/** From this many mm³ a volume is said in cm³, as a slicer says it. */
const MM3_PER_CM3 = 1000;

/**
 * `n` with at most `digits` decimals, the trailing ones left out, thousands grouped.
 * @param {number} n
 * @param {number} digits
 */
const decimal = (n, digits) => n.toLocaleString('en', { maximumFractionDigits: digits });

/** @param {number} mm */
export const formatLength = (mm) => decimal(mm, 2);

/** @param {number} mm2 */
export const formatArea = (mm2) => `${decimal(mm2, 1)} mm²`;

/** @param {number} mm3 */
export const formatVolume = (mm3) =>
  mm3 >= MM3_PER_CM3 ? `${decimal(mm3 / MM3_PER_CM3, 2)} cm³` : `${decimal(mm3, 1)} mm³`;

/**
 * A part as its tooltip names it: its name, and how many copies when more than one.
 * @param {Pick<Part, 'name' | 'count'>} part
 */
export const partTitle = (part) => (part.count > 1 ? `${part.name} ×${part.count}` : part.name);

/**
 * A part's volume and size (width × depth × height), or null when they weren't measured.
 * @param {Pick<Part, 'volume' | 'size'>} part
 * @returns {string | null}
 */
export function partMeasures(part) {
  if (part.volume === null || part.volume === undefined || !part.size) return null;
  return `${formatVolume(part.volume)} · ${part.size.map(formatLength).join(' × ')} mm`;
}

/**
 * A face as its tooltip says it: flat (with the axis it faces along, or its way) or curved, and
 * its area.
 * @param {Face} face
 */
export function faceLine(face) {
  if (!face.flat) return `Curved face · ${formatArea(face.area)}`;
  const way = face.facing ?? `(${(face.normal ?? []).map((v) => v.toFixed(2)).join(', ')})`;
  return `Flat face · ${formatArea(face.area)} · facing ${way}`;
}
