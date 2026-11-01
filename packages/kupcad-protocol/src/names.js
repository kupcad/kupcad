// A file's name as the hosts read it: its extension and its stem, split one way (each host
// split them itself, one of them taking `A.KUP` for no script and naming its export
// `A.KUP.stl`), and what a script's is.

/** A script's extension, without the dot. */
export const SCRIPT_EXTENSION = 'kup';

/**
 * A file name's extension, lower case, without the dot; null for a name without one (a hidden
 * name's leading dot is none). A path's is its last name's.
 * @param {string} name
 * @returns {string | null}
 */
export function extensionOf(name) {
  const base = name.slice(name.lastIndexOf('/') + 1);
  const dot = base.lastIndexOf('.');
  return dot <= 0 ? null : base.slice(dot + 1).toLowerCase();
}

/**
 * A file name without its extension, as an export or a screenshot is named after a script;
 * a name without one as it is.
 * @param {string} name
 * @returns {string}
 */
export function stemOf(name) {
  const base = name.slice(name.lastIndexOf('/') + 1);
  const dot = base.lastIndexOf('.');
  return dot <= 0 ? name : name.slice(0, name.length - (base.length - dot));
}

/**
 * Whether `name` is a script's, by its extension in any case.
 * @param {string} name
 */
export const isScriptName = (name) => extensionOf(name) === SCRIPT_EXTENSION;
