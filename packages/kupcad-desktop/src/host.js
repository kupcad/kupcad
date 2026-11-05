// The preview's host, in the page itself (@kupcad/ui's PreviewPanel talks to it as a ViewerHost):
// @kupcad/protocol's preview host over the app's services, so what the panel asks is done with
// the language server, the dialogs and the native side's export, and the panel is told the
// script shown, the values its parameters were given, and the server's log, for its console.
// An export runs one at a time, the window told while it does, for its Cancel.

import { childPath, nameOf, parentOf } from '@kupcad/files';
import {
  createPreviewHost,
  EXPORT_FORMATS,
  errorText,
  exportFormatFor,
  failureText,
  paramText,
  pngBytes,
  stemOf,
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
 * @property {(path: string) => Promise<boolean>} beforeExport readies the script at `path` for a
 *   build, which reads it from the disk (its changes saved); false when it isn't, and the export
 *   is let go
 * @property {(script: string, output: string, format: ExportFormat, params: [string, string][], memoryLimit: number) => Promise<void>} exportModel
 *   builds the script (the native side's `kupcad build`); rejects with what kupcad said, and
 *   when it is cancelled
 * @property {() => Promise<void>} cancelExport stops the build under way
 * @property {(name: string | null) => void} exporting the file an export under way writes, by
 *   its name; null once it is done
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
  /** Whether an export runs, and whether the person cancelled it. */
  const exported = { running: false, cancelled: false };
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
   * Exports `shown` in the format the page's menu chose (`exportTo`), unless an export is under
   * way: one at a time, and one cancelled says nothing more.
   * @param {ShownScript} shown
   * @param {ExportFormat} chosen
   */
  async function exportScript(shown, chosen) {
    if (exported.running) {
      services.log('An export is under way: cancel it, or wait for it to be done.');
      return;
    }
    Object.assign(exported, { running: true, cancelled: false });
    try {
      await exportTo(shown, chosen);
    } catch (error) {
      if (exported.cancelled) return;
      // kupcad is asked for its reason as JSON (the native side's build_args); its words are
      // read only when there is none
      const said = errorText(error);
      await services.tell(`${shown.name} wasn't exported: ${failureText(said, said)}`);
    } finally {
      exported.running = false;
    }
  }

  /**
   * Exports `shown` where the person says, its changes saved first: the build reads the disk.
   * The dialog is of the format chosen alone: one of every format offered no choice of them on
   * macOS, whose save panel lists the file types as one.
   * @param {ShownScript} shown
   * @param {ExportFormat} chosen
   */
  async function exportTo(shown, chosen) {
    // The page's message was checked to name one
    const choice = EXPORT_FORMATS.find(({ format }) => format === chosen);
    if (!choice || !(await services.beforeExport(shown.path))) return;
    const output = await services.save({
      title: `Export ${shown.name} as ${choice.label}`,
      defaultPath: beside(shown, `${stemOf(shown.name)}.${chosen}`),
      filters: [
        {
          name: `${choice.label}: ${choice.detail}`,
          extensions: [...choice.extensions],
        },
      ],
    });
    if (!output) return;
    const format = exportFormatFor(output, chosen);
    const params = Object.entries(host.values.of(shown.uri)).map(
      ([name, value]) => /** @type {[string, string]} */ ([name, paramText(value)]),
    );
    const name = nameOf(output);
    services.exporting(name);
    try {
      await services.exportModel(shown.path, output, format, params, services.memoryLimit());
    } finally {
      services.exporting(null);
    }
    services.log(`Exported ${name}.`);
  }

  /** @param {string} png the image's bytes in base64 */
  async function saveScreenshot(png) {
    const path = await services.save({
      title: 'Save the screenshot',
      defaultPath: script ? beside(script, `${stemOf(script.name)}.png`) : 'model.png',
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
    /** Stops the export under way, saying nothing of its end. */
    cancelExport() {
      if (!exported.running) return Promise.resolve();
      exported.cancelled = true;
      return services.cancelExport();
    },
  };
}

/**
 * The path of a file named `name` beside the script `shown`, where a dialog offers to save what
 * is made of it: a bare name opened the dialog wherever it was last.
 * @param {ShownScript} shown
 * @param {string} name
 */
const beside = (shown, name) => childPath(parentOf(shown.path), name);
