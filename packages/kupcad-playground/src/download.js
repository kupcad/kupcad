// A file the playground gives the user (an export, a screenshot): saved as the browser saves a
// link's download.

/**
 * Saves `data` as `name`.
 * @param {Blob | Uint8Array} data
 * @param {string} name
 */
export function download(data, name) {
  const blob = data instanceof Blob ? data : new Blob([/** @type {BlobPart} */ (data)]);
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = name;
  link.click();
  URL.revokeObjectURL(url);
}
