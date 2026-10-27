// The keys and the pointer's moves a person can't see on the screen, listed in ShortcutsDialog:
// the viewer's (VIEWER_SHORTCUTS), and a host's own groups before them. Named as the system
// names its keys: ⌘ and ⌥ on a Mac, Ctrl and Alt elsewhere.

/**
 * A group of shortcuts under its title: each a key, or keys pressed together, and what it does.
 * @typedef {object} ShortcutGroup
 * @property {string} title
 * @property {readonly (readonly [keys: string, what: string])[]} keys
 * @property {string} [note] what a person needs to know first (where the keys work)
 */

/** @typedef {'mac' | 'windows' | 'other'} KeyboardSystem */

/**
 * The system the page runs on, as its keys are named.
 * @param {string} [agent] the browser's user agent
 * @returns {KeyboardSystem}
 */
export function keyboardSystem(agent = globalThis.navigator?.userAgent ?? '') {
  if (/Mac|iPhone|iPad/.test(agent)) return 'mac';
  return agent.includes('Windows') ? 'windows' : 'other';
}

/**
 * The viewer's shortcuts, its keys named as `system` names them. Cmd is the Meta key, which
 * Windows calls Win and Linux Super.
 * @param {KeyboardSystem} system
 * @returns {ShortcutGroup}
 */
export function viewerShortcuts(system) {
  const alt = system === 'mac' ? '⌥' : 'Alt';
  const meta = system === 'mac' ? '⌘' : system === 'windows' ? 'Win' : 'Super';
  return {
    title: 'Viewer',
    note: 'Keys once the model has the focus: a click on it gives it.',
    keys: [
      ['0', 'Iso view'],
      ['1', 'Top view'],
      ['2', 'Bottom view'],
      ['3', 'Front view'],
      ['4', 'Back view'],
      ['5', 'Left view'],
      ['6', 'Right view'],
      ['F', 'Fit the model'],
      ['I', 'Zoom in'],
      ['O', 'Zoom out'],
      ['Drag', 'Turn the view'],
      ['Right or middle drag', 'Pan'],
      ['Wheel, pinch', 'Zoom'],
      ['Shift + wheel', 'Pan'],
      [`${alt} + wheel`, 'Move the section'],
      [`${meta} + wheel`, 'Turn the view'],
    ],
  };
}

/** The viewer's shortcuts on the system the page runs on. */
export const VIEWER_SHORTCUTS = viewerShortcuts(keyboardSystem());
