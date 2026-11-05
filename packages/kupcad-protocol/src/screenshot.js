// A screenshot as the page's message carries it to its host (`{ type: 'screenshot', png }`): the
// PNG's bytes in base64. VS Code takes a webview's messages to its extension as JSON alone, so
// the bytes go as text; the page wrote it in one package and the hosts read it in another.

/** How many bytes go to String.fromCharCode at once: it takes only so many arguments. */
const CHUNK_BYTES = 0x8000;

/**
 * A screenshot's bytes as the base64 the page sends them as.
 * @param {Uint8Array} bytes
 * @returns {string}
 */
export function pngBase64(bytes) {
  let text = '';
  for (let at = 0; at < bytes.length; at += CHUNK_BYTES) {
    text += String.fromCharCode(...bytes.subarray(at, at + CHUNK_BYTES));
  }
  return btoa(text);
}

/**
 * A screenshot's bytes from the base64 the page sends them as.
 * @param {string} png
 */
export const pngBytes = (png) => Uint8Array.from(atob(png), (c) => c.charCodeAt(0));
