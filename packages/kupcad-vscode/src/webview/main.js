// The viewer's page, in the extension's webview: themed by VS Code's colours, talking to the
// extension through the webview's API, and to the language server's socket, whose URL the
// extension wrote in the page.

import '@kupcad/ui/vscode.css';
import { PreviewPanel } from '@kupcad/ui';
import { mount } from 'svelte';
import { connectHost } from './bridge.js';

const viewport = document.querySelector('meta[name="kupcad-viewport"]');
mount(PreviewPanel, {
  target: /** @type {HTMLElement} */ (document.getElementById('app')),
  props: {
    host: connectHost(acquireVsCodeApi()),
    viewportUrl: viewport?.getAttribute('content') || null,
  },
});
