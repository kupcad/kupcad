// The app's page in Tauri's webview: @kupcad/ui's tokens (light or dark as the system is) and the
// window, on Tauri's services, laid out as the app's settings keep it. A release build looks for
// a newer version as it opens; `pnpm dev`'s doesn't (its menu still can).

import '@kupcad/ui/tokens.css';
import { memorySettings } from '@kupcad/ui';
import { mount } from 'svelte';
import App from './App.svelte';
import { tauri } from './platform.js';

mount(App, {
  target: /** @type {HTMLElement} */ (document.getElementById('app')),
  props: { platform: tauri, settings: await readSettings(), checkUpdates: !import.meta.env.DEV },
});

/** The app's settings; a file that can't be read leaves the window laid out as it starts. */
async function readSettings() {
  try {
    return await tauri.settings();
  } catch (error) {
    console.error(`The app's settings weren't read: ${error}`);
    return memorySettings();
  }
}
