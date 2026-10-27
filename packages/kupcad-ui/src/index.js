// @kupcad/ui, for Svelte: the viewer (Viewer), the panels a KupCAD host shows beside its editor,
// and a language server's preview (PreviewPanel, over its viewport socket, connectViewport).
// Styled by the --kc-* tokens of `@kupcad/ui/tokens.css` (or `@kupcad/ui/vscode.css` in VS
// Code's webview), which a page loads. The viewer for any host, Svelte or not, is
// `@kupcad/ui/viewer`.

export { default as ConsolePanel } from './ConsolePanel.svelte';
export { default as ExportMenu } from './ExportMenu.svelte';
export { default as ParamsPanel } from './ParamsPanel.svelte';
export { default as PreviewPanel } from './PreviewPanel.svelte';
export { default as ShortcutsDialog } from './ShortcutsDialog.svelte';
export { default as Splitter } from './Splitter.svelte';
export { default as Viewer } from './Viewer.svelte';
export { default as ViewerPane } from './ViewerPane.svelte';
export { appendLines, linesOfLog, linesOfRun } from './console.js';
export { fillOf } from './range.js';
export { problemsOf, runStatusOf } from './run-status.js';
export { localSettings, memorySettings, sizeSetting } from './settings.js';
export { VIEWER_SHORTCUTS } from './shortcuts.js';
export { watchTokens } from './theme.js';
export { plainValues } from './values.svelte.js';
export {
  ENVIRONMENTS,
  PROJECTIONS,
  VIEW_DEFAULTS,
  VIEW_KEYS,
  viewChoice,
  viewChoices,
} from './view-settings.js';
// What a settings page offers of the view: the viewer's render modes
export { RENDER_MODES } from './viewer/index.js';
export { connectViewport } from './viewport-socket.js';

/** @typedef {import('./console.js').ConsoleLine} ConsoleLine */
/** @typedef {import('./run-status.js').Problem} Problem */
/** @typedef {import('./run-status.js').RunStatus} RunStatus */
/** @typedef {import('./settings.js').Settings} Settings */
/** @typedef {import('./shortcuts.js').ShortcutGroup} ShortcutGroup */
/** @typedef {import('./view-settings.js').ViewChoices} ViewChoices */
/** @typedef {import('./viewport-socket.js').ViewportEvents} ViewportEvents */
