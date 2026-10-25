// The preview's host, in the page itself (@kupcad/ui's PreviewPanel talks to it as a ViewerHost):
// what the panel asks is done with the language server, the dialogs and the native side's
// export, and the panel is told the script shown and the values its parameters were given.

import { EXPORT_FORMATS, errorText, whyBuildFailed } from '@kupcad/protocol';

/** @import { ExportFormat, HostMessage, ParamValues, ViewerHost, ViewerMessage } from '@kupcad/protocol/types' */

/** A file's extensions as each format writes it; `.stp` is a STEP file too. */
const EXTENSIONS = new Map(
  EXPORT_FORMATS.map(({ format }) => [format, format === 'step' ? ['step', 'stp'] : [format]]),
);

/**
 * A script the app shows: its document as the server knows it, and where it is.
 * @typedef {object} ShownScript
 * @property {string} uri
 * @property {string} name its file's name
 * @property {string} path
 */

/**
 * What the host does its work with.
 * @typedef {object} HostServices
 * @property {{ preview(uri: string): Promise<unknown>, setParams(uri: string, values: ParamValues): Promise<unknown> }} server
 * @property {(options: { defaultPath: string, filters: { name: string, extensions: string[] }[], title: string }) => Promise<string | null>} save
 *   asks where to write a file
 * @property {(message: string) => Promise<void>} tell shows the person a message
 * @property {(script: string, output: string, format: ExportFormat, params: [string, string][]) => Promise<void>} exportModel
 *   builds the script (the native side's `kupcad build`); rejects with what kupcad said
 * @property {(path: string, bytes: Uint8Array) => Promise<void>} writeFile
 * @property {(uri: string, line: number, column: number) => void} reveal shows the script there
 * @property {(text: string) => void} log
 */

/**
 * The host, and what the app tells it: the script it shows.
 * @param {HostServices} services
 */
export function createHost(services) {
  /** @type {Set<(message: HostMessage) => void>} */
  const listeners = new Set();
  /** The values each script's parameters were given, by its URI, kept while the app runs. */
  const values = new Map();
  /** @type {ShownScript | null} */
  let shown = null;

  /** @param {HostMessage} message */
  const tell = (message) => {
    for (const listener of listeners) listener(message);
  };
  const tellDocument = () => {
    tell({ type: 'document', document: shown && { uri: shown.uri, name: shown.name } });
    if (shown) tell({ type: 'overrides', uri: shown.uri, values: values.get(shown.uri) ?? {} });
  };
  /**
   * @param {Promise<unknown>} asked
   * @param {string} what
   */
  const report = (asked, what) =>
    void asked.catch((error) => services.log(`${what} failed: ${errorText(error)}`));

  /** @param {ShownScript} script */
  async function exportScript(script) {
    const stem = script.name.replace(/\.kup$/, '');
    const output = await services.save({
      title: `Export ${script.name}`,
      defaultPath: `${stem}.stl`,
      filters: EXPORT_FORMATS.map(({ format, label, detail }) => ({
        name: `${label}: ${detail}`,
        extensions: /** @type {string[]} */ (EXTENSIONS.get(format)),
      })),
    });
    if (!output) return;
    const format = formatOf(output);
    if (!format) {
      const known = [...EXTENSIONS.values()].flat().map((ext) => `.${ext}`);
      await services.tell(
        `${output} names no format kupcad writes: save it as ${known.join(', ')}`,
      );
      return;
    }
    const params = Object.entries(values.get(script.uri) ?? {}).map(
      ([name, value]) => /** @type {[string, string]} */ ([name, String(value)]),
    );
    try {
      await services.exportModel(script.path, output, format, params);
    } catch (error) {
      const said = errorText(error);
      await services.tell(`${script.name} wasn't exported: ${whyBuildFailed(said) ?? said}`);
    }
  }

  /** @param {string} png the image's bytes in base64 */
  async function saveScreenshot(png) {
    const stem = shown?.name.replace(/\.kup$/, '') ?? 'model';
    const path = await services.save({
      title: 'Save the screenshot',
      defaultPath: `${stem}.png`,
      filters: [{ name: 'PNG image', extensions: ['png'] }],
    });
    if (path)
      await services.writeFile(
        path,
        Uint8Array.from(atob(png), (c) => c.charCodeAt(0)),
      );
  }

  /** @param {ViewerMessage} message */
  function handle(message) {
    // The panel acts on the script shown and on no other
    if ('uri' in message && message.uri !== shown?.uri) {
      services.log(`The preview named ${message.uri}, which it isn't shown: refused`);
      return;
    }
    switch (message.type) {
      case 'ready':
        tellDocument();
        if (shown) report(services.server.preview(shown.uri), 'Showing the script');
        return;
      case 'setParams':
        values.set(message.uri, message.values);
        report(services.server.setParams(message.uri, message.values), 'Giving the values');
        return;
      case 'export':
        if (shown) report(exportScript(shown), 'The export');
        return;
      case 'screenshot':
        report(saveScreenshot(message.png), 'Saving the screenshot');
        return;
      case 'problem':
        services.log(`The preview: ${message.message}`);
        return;
      case 'reveal':
        services.reveal(message.uri, message.line, message.column);
        return;
      // Presets aren't offered (PreviewPanel's `presets`)
      case 'applyPreset':
      case 'savePreset':
        return;
    }
  }

  /** @type {ViewerHost} */
  const host = {
    post: handle,
    listen(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };

  return {
    host,
    /**
     * Shows `script` from now on (none for null), and has its frame sent.
     * @param {ShownScript | null} script
     */
    show(script) {
      if (script?.uri === shown?.uri) return;
      shown = script;
      tellDocument();
      if (shown) report(services.server.preview(shown.uri), 'Showing the script');
    },
  };
}

/**
 * The format a file named `path` is written in, by its extension; null for none kupcad writes.
 * @param {string} path
 * @returns {ExportFormat | null}
 */
export function formatOf(path) {
  const extension = path.slice(path.lastIndexOf('.') + 1).toLowerCase();
  for (const [format, extensions] of EXTENSIONS) if (extensions.includes(extension)) return format;
  return null;
}
