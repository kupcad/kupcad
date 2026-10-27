// The viewer's page, in the extension's webview: themed by VS Code's colours, talking to the
// extension through the webview's API, and to the language server's socket, whose URL the
// extension wrote in the page with the settings it kept.

import '@kupcad/ui/vscode.css';
import './page.css';
import { PreviewPanel } from '@kupcad/ui';
import { mount } from 'svelte';
import { connectHost, hostSettings } from './bridge.js';

// The page may ask for the webview's API once
const api = acquireVsCodeApi();
const viewport = document.querySelector('meta[name="kupcad-viewport"]');
mount(PreviewPanel, {
  target: /** @type {HTMLElement} */ (document.getElementById('app')),
  props: {
    host: connectHost(api),
    viewportUrl: viewport?.getAttribute('content') || null,
    settings: hostSettings(api),
  },
});
