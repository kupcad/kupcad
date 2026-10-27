// How far along a range input's thumb is, for controls.css's .kc-range: WebKit and Blink fill
// no track of their own, so the panel sets this as --kc-range-fill as the value changes.

/**
 * `value`'s place between `min` and `max` as a CSS percentage, held to 0% and 100%. A range
 * input with no value puts its thumb half way, and so does this; a span that is none, at 0%.
 * @param {unknown} value
 * @param {number | string | null} [min] the input's (none: a browser's default, 0)
 * @param {number | string | null} [max] the input's (none: a browser's default, 100)
 * @returns {string}
 */
export function fillOf(value, min, max) {
  const low = Number(min ?? 0);
  const high = Number(max ?? 100);
  if (!Number.isFinite(low) || !Number.isFinite(high) || high <= low) return '0%';
  const at = value === null || value === undefined || value === '' ? NaN : Number(value);
  if (!Number.isFinite(at)) return '50%';
  return `${Math.min(100, Math.max(0, ((at - low) / (high - low)) * 100))}%`;
}
