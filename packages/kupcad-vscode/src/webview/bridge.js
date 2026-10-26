// The page's side of the messages with the extension: what it asks (`ViewerMessage`) goes out
// through the webview's API, and what the extension tells it (`HostMessage`) comes in as window
// messages, each checked: anything else is dropped. Its settings come in the page, as the
// extension kept them, and each change goes out for it to keep.

import { isHostMessage, isSettingValue } from '@kupcad/protocol';
import { memorySettings } from '@kupcad/ui';

/** @import { ViewerHost } from '@kupcad/protocol/types' */
/** @import { Settings } from '@kupcad/ui' */
/** @import { WebviewApi } from '../types.js' */

/**
 * The extension, as the page talks to it.
 * @param {WebviewApi} api `acquireVsCodeApi()`'s
 * @param {Window} [window]
 * @returns {ViewerHost}
 */
export function connectHost(api, window = globalThis.window) {
  return {
    post: (message) => api.postMessage(message),
    listen(listener) {
      /** @param {MessageEvent} event */
      const received = (event) => {
        if (isHostMessage(event.data)) listener(event.data);
      };
      window.addEventListener('message', received);
      return () => window.removeEventListener('message', received);
    },
  };
}

/**
 * The page's settings (its panes' sizes, whether they show): those the extension kept, which
 * it wrote in the page, each one changed sent to it to keep.
 * @param {WebviewApi} api `acquireVsCodeApi()`'s
 * @param {Document} [document]
 * @returns {Settings}
 */
export function hostSettings(api, document = globalThis.document) {
  const settings = memorySettings(keptSettings(document));
  return {
    get: settings.get,
    set(key, value) {
      settings.set(key, value);
      if (isSettingValue(value)) api.postMessage({ type: 'setting', key, value });
    },
  };
}

/**
 * The settings the extension wrote in the page; none where it wrote no object of them.
 * @param {Document} document
 * @returns {Record<string, unknown>}
 */
function keptSettings(document) {
  const text = document.querySelector('meta[name="kupcad-settings"]')?.getAttribute('content');
  try {
    const kept = JSON.parse(text || '{}');
    return typeof kept === 'object' && kept !== null && !Array.isArray(kept) ? kept : {};
  } catch {
    return {};
  }
}
