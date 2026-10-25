// @kupcad/ui: the panels a KupCAD host shows beside its editor, and a language server's preview
// (PreviewPanel, over its viewport socket, connectViewport). Styled by the --kc-* tokens of
// `@kupcad/ui/tokens.css` (or `@kupcad/ui/vscode.css` in VS Code's webview), which a page loads.

export { default as ConsolePanel } from './ConsolePanel.svelte';
export { default as ParamsPanel } from './ParamsPanel.svelte';
export { default as PreviewPanel } from './PreviewPanel.svelte';
export { default as Splitter } from './Splitter.svelte';
export { default as ViewerPane } from './ViewerPane.svelte';
export { appendLines, linesOfLog, linesOfRun } from './console.js';
export { problemsOf, runStatusOf } from './run-status.js';
export { localSettings, memorySettings, sizeSetting } from './settings.js';
export { watchTokens } from './theme.js';
export { connectViewport } from './viewport-socket.js';

/** @typedef {import('./console.js').ConsoleLine} ConsoleLine */
/** @typedef {import('./run-status.js').Problem} Problem */
/** @typedef {import('./run-status.js').RunStatus} RunStatus */
/** @typedef {import('./settings.js').Settings} Settings */
/** @typedef {import('./viewport-socket.js').ViewportEvents} ViewportEvents */
