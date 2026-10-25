// The app's page in Tauri's webview: @kupcad/ui's tokens (light or dark as the system is) and the
// window, on Tauri's services.

import '@kupcad/ui/tokens.css';
import { mount } from 'svelte';
import App from './App.svelte';
import { tauri } from './platform.js';

mount(App, {
  target: /** @type {HTMLElement} */ (document.getElementById('app')),
  props: { platform: tauri },
});
