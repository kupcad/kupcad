import { describe, expect, it } from 'vitest';
import { keyboardSystem, VIEWER_SHORTCUTS, viewerShortcuts } from './shortcuts.js';

/**
 * The wheel's modifiers, as `system` names them, but Shift: the section's, then the turn's.
 * @param {import('./shortcuts.js').KeyboardSystem} system
 */
const wheelModifiers = (system) =>
  viewerShortcuts(system)
    .keys.map(([keys]) => keys)
    .filter((keys) => keys.endsWith('+ wheel') && !keys.startsWith('Shift'));

describe('shortcuts', () => {
  it('tell the system by its browser, as its keys are named', () => {
    expect(
      keyboardSystem('Mozilla/5.0 (Macintosh; Intel Mac OS X 15_6) AppleWebKit/605.1.15'),
    ).toBe('mac');
    expect(keyboardSystem('Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/140.0')).toBe(
      'windows',
    );
    expect(keyboardSystem('Mozilla/5.0 (X11; Linux x86_64) Chrome/140.0')).toBe('other');
  });

  it("list the viewer's keys, each view's digit, and its pointer and wheel", () => {
    const keys = new Map(viewerShortcuts('other').keys);
    expect([...'0123456'].map((digit) => keys.get(digit))).toEqual([
      'Iso view',
      'Top view',
      'Bottom view',
      'Front view',
      'Back view',
      'Left view',
      'Right view',
    ]);
    expect(['F', 'I', 'O'].map((key) => keys.get(key))).toEqual([
      'Fit the model',
      'Zoom in',
      'Zoom out',
    ]);
    expect(keys.get('Shift + wheel')).toBe('Pan');
    expect(VIEWER_SHORTCUTS.title).toBe('Viewer');
  });

  it("name the wheel's modifiers as each system does", () => {
    expect(wheelModifiers('mac')).toEqual(['⌥ + wheel', '⌘ + wheel']);
    expect(wheelModifiers('windows')).toEqual(['Alt + wheel', 'Win + wheel']);
    expect(wheelModifiers('other')).toEqual(['Alt + wheel', 'Super + wheel']);
  });
});
