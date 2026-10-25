// The viewer's colours: what a host maps its own tokens into (the VS Code webview its
// --vscode-* variables, the playground its page's). Any CSS colour.

/** @import { Theme } from './types.js' */

/** @type {Theme} */
export const LIGHT = {
  background: '#f4f5f7',
  grid: '#d3d6db',
  plate: '#e6e8eb',
  edges: '#2b2f36',
  wire: '#2b2f36',
  selection: '#2f80ed',
  cap: '#e0605a',
  ghost: '#6f8fb8',
  highlight: '#d6409f',
};

/** @type {Theme} */
export const DARK = {
  background: '#1e2024',
  grid: '#3a3e45',
  plate: '#2a2d32',
  edges: '#0d0e10',
  wire: '#c5cad3',
  selection: '#5aa0ff',
  cap: '#e0605a',
  ghost: '#7f9fcc',
  highlight: '#f06cb8',
};
