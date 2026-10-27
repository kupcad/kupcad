// Bytes as base64, which the page's messages carry a screenshot in.

/** How many bytes go to String.fromCharCode at once: it takes only so many arguments. */
const CHUNK_BYTES = 0x8000;

/**
 * @param {Uint8Array} bytes
 * @returns {string}
 */
export function toBase64(bytes) {
  let text = '';
  for (let at = 0; at < bytes.length; at += CHUNK_BYTES) {
    text += String.fromCharCode(...bytes.subarray(at, at + CHUNK_BYTES));
  }
  return btoa(text);
}
