import { describe, expect, it } from 'vitest';
import { THEMES, themeOf } from './theme.js';

describe('themeOf', () => {
  it('reads each theme the settings keep', () => {
    for (const [name] of THEMES) expect(themeOf(name)).toBe(name);
  });

  it("reads none, or what isn't a theme, as the system's", () => {
    for (const kept of [undefined, null, '', 'Dark', 'sepia', 1, true]) {
      expect(themeOf(kept)).toBe('system');
    }
  });
});
