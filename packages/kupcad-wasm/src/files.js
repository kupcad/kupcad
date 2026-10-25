// The files a call gives the core, packed into one buffer as the core reads them
// (core/src/vfs/packed.zig): each file its path, then its content, each with its length first
// (u32, little-endian), one after another. One buffer crosses into the module's memory, however
// many files; the core keeps them for that call alone.

/** A length, as written before a path and before a content. */
const LEN_BYTES = 4;

const encoder = new TextEncoder();

/**
 * `files` packed: paths as the script names them (`import { } from "./lib.kup"` reads
 * `lib.kup`; `import_json("data/size.json")` reads `data/size.json`) to their contents.
 * @param {Record<string, Uint8Array | string>} files
 * @returns {Uint8Array}
 */
export function packFiles(files) {
  const fields = Object.entries(files).flatMap(([path, content]) => [
    encoder.encode(path),
    typeof content === 'string' ? encoder.encode(content) : content,
  ]);
  const packed = new Uint8Array(
    fields.reduce((total, field) => total + LEN_BYTES + field.byteLength, 0),
  );
  const view = new DataView(packed.buffer);
  let at = 0;
  for (const field of fields) {
    view.setUint32(at, field.byteLength, true);
    packed.set(field, at + LEN_BYTES);
    at += LEN_BYTES + field.byteLength;
  }
  return packed;
}
