// The page's side of the messages with the extension: what it asks (`ViewerMessage`) goes out
// through the webview's API, and what the extension tells it (`HostMessage`) comes in as window
// messages, each checked: anything else is dropped.

import { isHostMessage } from '@kupcad/protocol';

/** @import { ViewerHost } from '@kupcad/protocol/types' */
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
