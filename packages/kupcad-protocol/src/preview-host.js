// The host of a preview page, as the VS Code extension's panel and the desktop app's page have
// one: what the page asks (a ViewerMessage) done through the host's services, and what the page
// is told (a HostMessage): the document shown, the values its parameters were given, its presets,
// the server's log. Each host handled the messages itself, and the two drifted (one told the
// page its values only when it had some, the other always; two decoders of a screenshot).

import { errorText } from './error-text.js';
import { anotherDocument, ScriptValues } from './host.js';

/** @import { ExportFormat, HostMessage, ParamValues, SettingValue, ShownDocument, ViewerMessage } from './types.js' */

/**
 * What a host does the page's asking with.
 * @typedef {object} PreviewServices
 * @property {{ preview(uri: string): Promise<unknown>, setParams(uri: string, values: ParamValues): Promise<unknown> }} server
 * @property {ScriptValues} [values] the values each script's parameters were given, shared with
 *   whatever else builds the script (VS Code's export command); the host's own when none
 * @property {(text: string) => void} warn a message refused, or a problem the page reports
 * @property {(text: string) => void} fail a request to the server that failed
 * @property {(uri: string, format: ExportFormat) => void} export
 * @property {(png: string) => void} screenshot the image's bytes in base64 (`pngBytes`)
 * @property {(uri: string, line: number, column: number, file: string | null) => void} reveal
 *   shows the script there; with a `file`, that module of the project (a library) instead
 * @property {(uri: string) => void} [presets] tells the page the document's presets
 *   (`tellPresets`), asked whenever the document is told; none offered without it
 * @property {(uri: string, name: string) => void} [applyPreset]
 * @property {(uri: string, values: ParamValues) => void} [savePreset]
 * @property {(key: string, value: SettingValue) => void} [keepSetting] keeps a setting of the
 *   page's; a host whose page keeps its own settings leaves it out
 */

/**
 * A preview page's host over `services`: `post` takes the page's messages, `listen` gives it
 * the host's.
 * @param {PreviewServices} services
 */
export function createPreviewHost(services) {
  /** @type {Set<(message: HostMessage) => void>} */
  const listeners = new Set();
  const values = services.values ?? new ScriptValues();
  /** @type {ShownDocument | null} */
  let shown = null;

  /** @param {HostMessage} message */
  const tell = (message) => {
    for (const listener of listeners) listener(message);
  };
  /**
   * @param {Promise<unknown>} request
   * @param {string} what
   */
  const ask = (request, what) =>
    void request.catch((error) => services.fail(`${what} failed: ${errorText(error)}`));
  /** Tells the page the document shown, the values it was given (when any) and its presets. */
  const tellDocument = () => {
    tell({ type: 'document', document: shown });
    if (!shown) return;
    if (values.has(shown.uri))
      tell({ type: 'overrides', uri: shown.uri, values: values.of(shown.uri) });
    services.presets?.(shown.uri);
  };
  /**
   * Asks the server for the frame of the document shown, its values given first: a server
   * forgets them as it ends, so one started again (the page ready on its socket), or while
   * another document was shown, ran it with its defaults, which the panel didn't show and an
   * export didn't build.
   */
  const preview = () => {
    if (!shown) return;
    if (values.has(shown.uri))
      ask(services.server.setParams(shown.uri, values.of(shown.uri)), 'Giving the values');
    ask(services.server.preview(shown.uri), 'Showing the script');
  };

  /** @param {ViewerMessage} message */
  function post(message) {
    // The page acts on the document shown, and on no other: a page naming another would have
    // the host write beside it, build it or open it
    const another = anotherDocument(message, shown);
    if (another !== null) {
      services.warn(`The page named ${another}, which it isn't shown: refused`);
      return;
    }
    switch (message.type) {
      case 'ready':
        // A page loaded again (a new port, a reload) knows nothing yet, nor a server started
        // again
        tellDocument();
        preview();
        return;
      case 'setParams':
        values.set(message.uri, message.values);
        ask(services.server.setParams(message.uri, message.values), 'Giving the values');
        return;
      case 'applyPreset':
        services.applyPreset?.(message.uri, message.name);
        return;
      case 'savePreset':
        services.savePreset?.(message.uri, message.values);
        return;
      case 'export':
        services.export(message.uri, message.format);
        return;
      case 'screenshot':
        services.screenshot(message.png);
        return;
      case 'problem':
        services.warn(`The page: ${message.message}`);
        return;
      case 'reveal':
        services.reveal(message.uri, message.line, message.column, message.file ?? null);
        return;
      case 'setting':
        services.keepSetting?.(message.key, message.value);
        return;
    }
  }

  return {
    post,
    /** @param {(message: HostMessage) => void} listener */
    listen(listener) {
      listeners.add(listener);
      return () => void listeners.delete(listener);
    },
    /** The document shown, or null. */
    get shown() {
      return shown;
    },
    values,
    /**
     * Shows `document` from now on (none for null): the page is told, and the server given its
     * values and asked for its frame. The same document again changes nothing.
     * @param {ShownDocument | null} document
     */
    show(document) {
      if (document?.uri === shown?.uri) return;
      shown = document;
      tellDocument();
      preview();
    },
    /**
     * Gives the script at `uri` `given` (a preset applied): the server runs it with them, and
     * the page's panel shows them when it is the document shown.
     * @param {string} uri
     * @param {ParamValues} given
     */
    setValues(uri, given) {
      values.set(uri, given);
      if (shown?.uri === uri) tell({ type: 'overrides', uri, values: given });
      ask(services.server.setParams(uri, given), 'Giving the values');
    },
    /**
     * Tells the page the names of the presets of the script at `uri`.
     * @param {string} uri
     * @param {string[]} names
     */
    tellPresets(uri, names) {
      tell({ type: 'presets', uri, names });
    },
    /**
     * Gives the page's console `text`, lines of the server's log.
     * @param {string} text
     */
    log(text) {
      tell({ type: 'log', text });
    },
  };
}

/**
 * A screenshot's bytes from the base64 the page sends them as.
 * @param {string} png
 */
export const pngBytes = (png) => Uint8Array.from(atob(png), (c) => c.charCodeAt(0));
