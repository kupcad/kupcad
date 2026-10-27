import { describe, expect, it } from 'vitest';
import { faceLine, formatVolume, partMeasures, partTitle } from './measures.js';

describe("the tooltip's measures", () => {
  it('names a part with its copies, and says its volume and size, a large one in cm³', () => {
    expect(partTitle({ name: 'bolt', count: 2 })).toBe('bolt ×2');
    expect(partTitle({ name: 'plate', count: 1 })).toBe('plate');
    expect(partMeasures({ volume: 62.832, size: [4, 4, 5] })).toBe('62.8 mm³ · 4 × 4 × 5 mm');
    expect(partMeasures({ volume: 15625, size: [25, 25, 25] })).toBe('15.63 cm³ · 25 × 25 × 25 mm');
    expect(partMeasures({ volume: null, size: null })).toBeNull();
    expect(partMeasures({})).toBeNull();
    expect(formatVolume(1234567)).toBe('1,234.57 cm³');
  });

  it('says a face: flat, facing an axis or its way, or curved, with its area', () => {
    expect(faceLine({ flat: true, area: 342, normal: [0, 0, 1], facing: '+Z (top)' })).toBe(
      'Flat face · 342 mm² · facing +Z (top)',
    );
    expect(
      faceLine({ flat: true, area: 12.345, normal: [Math.SQRT1_2, 0, Math.SQRT1_2], facing: null }),
    ).toBe('Flat face · 12.3 mm² · facing (0.71, 0.00, 0.71)');
    expect(faceLine({ flat: false, area: 1234.56, normal: null, facing: null })).toBe(
      'Curved face · 1,234.6 mm²',
    );
  });
});
