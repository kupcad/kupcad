// The preview's host, in the page itself (@kupcad/ui's PreviewPanel talks to it as a ViewerHost):
// @kupcad/protocol's preview host over the app's services, so what the panel asks is done with
// the language server, the dialogs and the native side's export, and the panel is told the
// script shown, the values its parameters were given, and the server's log, for its console.

import {
  buildFailure,
  createPreviewHost,
  EXPORT_FORMATS,
  errorText,
  formatOf,
  paramText,
  pngBytes,
  stemOf,
  whyBuildFailed,
} from '@kupcad/protocol';

/** @import { ExportFormat, ParamValues, ViewerHost } from '@kupcad/protocol/types' */

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
 * @property {(script: string, output: string, format: ExportFormat, params: [string, string][], memoryLimit: number) => Promise<void>} exportModel
 *   builds the script (the native side's `kupcad build`); rejects with what kupcad said
 * @property {() => number} memoryLimit the most memory, in GB, a build may hold (the setting)
 * @property {(path: string, bytes: Uint8Array) => Promise<void>} writeFile
 * @property {(uri: string, line: number, column: number, file: string | null) => void} reveal
 *   shows the script there; with a `file`, that module of the folder (a library) instead
 * @property {(text: string) => void} log
 */

/**
 * The host, and what the app tells it: the script it shows.
 * @param {HostServices} services
 */
export function createHost(services) {
  /** @type {ShownScript | null} */
  let script = null;
  const host = createPreviewHost({
    server: services.server,
    warn: services.log,
    fail: services.log,
    export: (_uri, format) => {
      if (script) report(exportScript(script, format), 'The export');
    },
    screenshot: (png) => report(saveScreenshot(png), 'Saving the screenshot'),
    reveal: services.reveal,
    // Presets aren't offered (PreviewPanel's `presets`), and the panel keeps its settings in
    // the app's settings file itself (App's `settings`)
  });
  /**
   * @param {Promise<unknown>} asked
   * @param {string} what
   */
  const report = (asked, what) =>
    void asked.catch((error) => services.log(`${what} failed: ${errorText(error)}`));

  /**
   * Exports `shown` in the format the page's menu chose, where the person says. The dialog is
   * of that format alone: one of every format offered no choice of them on macOS, whose save
   * panel lists the file types as one.
   * @param {ShownScript} shown
   * @param {ExportFormat} chosen
   */
  async function exportScript(shown, chosen) {
    const stem = stemOf(shown.name);
    // The page's message was checked to name one
    const choice = EXPORT_FORMATS.find(({ format }) => format === chosen);
    if (!choice) return;
    const output = await services.save({
      title: `Export ${shown.name} as ${choice.label}`,
      defaultPath: `${stem}.${chosen}`,
      filters: [
        {
          name: `${choice.label}: ${choice.detail}`,
          extensions: [...choice.extensions],
        },
      ],
    });
    if (!output) return;
    const format = formatOf(output);
    if (!format) {
      const known = EXPORT_FORMATS.flatMap((f) => f.extensions).map((ext) => `.${ext}`);
      await services.tell(
        `${output} names no format kupcad writes: save it as ${known.join(', ')}`,
      );
      return;
    }
    const params = Object.entries(host.values.of(shown.uri)).map(
      ([name, value]) => /** @type {[string, string]} */ ([name, paramText(value)]),
    );
    try {
      await services.exportModel(shown.path, output, format, params, services.memoryLimit());
    } catch (error) {
      // kupcad is asked for its reason as JSON (the native side's build_args); its words are
      // read only when there is none
      const said = errorText(error);
      const why = buildFailure(said)?.message ?? whyBuildFailed(said) ?? said;
      await services.tell(`${shown.name} wasn't exported: ${why}`);
    }
  }

  /** @param {string} png the image's bytes in base64 */
  async function saveScreenshot(png) {
    const stem = script ? stemOf(script.name) : 'model';
    const path = await services.save({
      title: 'Save the screenshot',
      defaultPath: `${stem}.png`,
      filters: [{ name: 'PNG image', extensions: ['png'] }],
    });
    if (path) await services.writeFile(path, pngBytes(png));
  }

  return {
    /** @type {ViewerHost} */
    host: { post: host.post, listen: host.listen },
    /**
     * Shows `next` from now on (none for null), and has its frame sent.
     * @param {ShownScript | null} next
     */
    show(next) {
      script = next;
      host.show(next ? { uri: next.uri, name: next.name } : null);
    },
    /**
     * Gives the panel's console `text`, lines of the server's log.
     * @param {string} text
     */
    log(text) {
      host.log(text);
    },
  };
}
