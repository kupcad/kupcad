// The viewer's colours: what a host maps its own tokens into (the VS Code webview its
// --vscode-* variables, the playground its page's). Any CSS colour. By default the KupCAD brand:
// a picked part in its orangered, on the neutrals of @kupcad/ui's tokens; a section's cut
// faces in dodgerblue, so no other warm colour reads as the selection.

/** @import { Theme } from './types.js' */

/** @type {Theme} */
export const LIGHT = {
  background: '#eef1f4',
  grid: '#c9cfd6',
  plate: '#e3e7eb',
  edges: '#1a1b1c',
  wire: '#1a1b1c',
  selection: '#ff5f14',
  cap: '#0099ff',
  ghost: '#7d8794',
  highlight: '#d6409f',
};

/** @type {Theme} */
export const DARK = {
  background: '#131415',
  grid: '#2e2f32',
  plate: '#1f2022',
  edges: '#0b0b0c',
  wire: '#c9ced4',
  selection: '#ff5f14',
  cap: '#3daeff',
  ghost: '#8a94a1',
  highlight: '#f06cb8',
};
