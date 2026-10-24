// The kupcad the extension runs: found (resolve.js), else the newest release in the extension's
// range installed in its storage (install.js), and that install kept up to date. This is what
// the user sees of it: a download's progress, why one failed and what to do, an update to take.

import * as vscode from 'vscode';
import { errorText } from '../../errors.js';
import { install as installRelease } from './install.js';
import { probe as probeVersion } from './probe.js';
import { newestInRange, readReleases as readReleaseList, RELEASES_PAGE } from './releases.js';
import { findServer } from './resolve.js';
import { compareVersions, parseVersion } from './versions.js';

/** @import { VersionInfo } from '@kupcad/protocol/types' */
/** @import { Release, ReleaseList } from './releases.js' */
/** @import { Found } from './resolve.js' */
/** @import { Version } from './versions.js' */

export const CHECK_FOR_UPDATES_COMMAND = 'kupcad.checkForUpdates';
/** An update is looked for once a day, at most, unless asked. */
export const UPDATE_EVERY_MS = 24 * 60 * 60 * 1000;
/** What the extension keeps between sessions: the last releases read (their ETag), and when. */
const RELEASES_KEY = 'kupcad.releases';
const CHECKED_KEY = 'kupcad.updatesCheckedAt';
const OPEN_SETTINGS = 'Open Settings';
const OPEN_RELEASES = 'Open Releases';
const UPDATE = 'Update';
const PERCENT = 100;

/**
 * @typedef {object} ManagerOptions
 * @property {string} range the core versions the extension runs with (`kupcad.core`)
 * @property {string} managedDir where its own installs go
 * @property {string} extensionPath
 * @property {vscode.Memento} state what it keeps between sessions
 * @property {vscode.LogOutputChannel} log
 * @property {() => vscode.WorkspaceConfiguration} settings its settings (`kupcad.*`), as they are now
 * @property {typeof fetch} [get]
 * @property {(path: string) => Promise<VersionInfo | null>} [probe]
 * @property {typeof findServer} [find]
 * @property {typeof installRelease} [install]
 * @property {typeof readReleaseList} [readReleases]
 * @property {() => number} [now]
 */

export class BinaryManager {
  /** @type {Required<ManagerOptions>} */
  #options;
  /** The kupcad running now, once one is. @type {Found | null} */
  #running = null;

  /** @param {ManagerOptions} options */
  constructor(options) {
    this.#options = {
      get: globalThis.fetch,
      probe: probeVersion,
      find: findServer,
      install: installRelease,
      readReleases: readReleaseList,
      now: Date.now,
      ...options,
    };
  }

  /**
   * The kupcad to run: one found, else the newest release in range installed (its download's
   * progress shown); null when there is neither, the user told why and what to do.
   * @returns {Promise<Found | null>}
   */
  async server() {
    const { range, managedDir, extensionPath, probe, log } = this.#options;
    const configured = this.#options.settings().get('serverPath');
    const { found, notes } = await this.#options.find({
      configured,
      managedDir,
      extensionPath,
      range,
      probe,
    });
    for (const note of notes) log.warn(note);
    // The user chose it: one out of range is run, with a word; one that isn't kupcad, not at all
    if (configured) {
      if (found && notes.length > 0) void vscode.window.showWarningMessage(notes[0]);
      if (!found) void this.#tellBadSetting(notes[0]);
      return (this.#running = found);
    }
    if (found) return (this.#running = found);

    try {
      const release = newestInRange((await this.#releases()).releases, range, this.#channel());
      if (!release) throw new Error(`no release of kupcad is in ${range} yet`);
      const path = await this.#install(release);
      return (this.#running = { path, version: release.version, source: 'managed' });
    } catch (error) {
      log.error(`kupcad couldn't be installed: ${errorText(error)}`);
      void this.#tellNotInstalled(errorText(error));
      return null;
    }
  }

  /**
   * Looks for a newer release in range of the extension's own install, once a day unless
   * `asked`: one is installed at once with `kupcad.binary.autoUpdate`, else when the user takes
   * it. A newer release out of range says the extension needs updating first.
   * @param {{ asked: boolean }} how
   * @returns {Promise<string | null>} the new install's path, for the server to run, or null
   */
  async checkForUpdates({ asked }) {
    const running = this.#running;
    const { state, now, log } = this.#options;
    if (!running) return null;
    if (running.source !== 'managed') {
      if (asked) {
        void vscode.window.showInformationMessage(
          `The kupcad running (${running.path}) isn't the extension's own: update it where it came from.`,
        );
      }
      return null;
    }
    const checked = state.get(CHECKED_KEY, 0);
    if (!asked && now() - checked < UPDATE_EVERY_MS) return null;

    /** @type {ReleaseList} */
    let list;
    try {
      list = await this.#releases();
    } catch (error) {
      log.warn(`couldn't look for a newer kupcad: ${errorText(error)}`);
      if (asked)
        void vscode.window.showErrorMessage(
          `Couldn't look for a newer kupcad: ${errorText(error)}`,
        );
      return null;
    }
    await state.update(CHECKED_KEY, now());
    const current = /** @type {Version} */ (parseVersion(running.version));
    const newer = (/** @type {Release | null} */ release) =>
      release !== null &&
      compareVersions(/** @type {Version} */ (parseVersion(release.version)), current) > 0;

    const inRange = newestInRange(list.releases, this.#options.range, this.#channel());
    if (inRange && newer(inRange)) {
      const take =
        this.#options.settings().get('binary.autoUpdate', true) ||
        (await vscode.window.showInformationMessage(
          `kupcad ${inRange.version} is out (this is ${running.version}).`,
          UPDATE,
        )) === UPDATE;
      if (!take) return null;
      try {
        const path = await this.#install(inRange);
        this.#running = { path, version: inRange.version, source: 'managed' };
        return path;
      } catch (error) {
        log.error(`kupcad ${inRange.version} couldn't be installed: ${errorText(error)}`);
        void vscode.window.showErrorMessage(
          `kupcad ${inRange.version} couldn't be installed: ${errorText(error)}`,
        );
        return null;
      }
    }
    const beyond = newestInRange(list.releases, '>=0.0.0', this.#channel());
    if (beyond && newer(beyond)) {
      void vscode.window.showInformationMessage(
        `kupcad ${beyond.version} is out, for a newer version of this extension: update the extension to run it.`,
      );
    } else if (asked) {
      void vscode.window.showInformationMessage(`kupcad ${running.version} is the newest.`);
    }
    return null;
  }

  /** The releases as GitHub lists them now, the last list kept for its ETag. */
  async #releases() {
    const { state, get } = this.#options;
    const list = await this.#options.readReleases(get, state.get(RELEASES_KEY, null));
    await state.update(RELEASES_KEY, list);
    return list;
  }

  /**
   * Installs `release`, its download's progress shown.
   * @param {Release} release
   */
  #install(release) {
    const { get, managedDir } = this.#options;
    return vscode.window.withProgress(
      {
        location: vscode.ProgressLocation.Notification,
        title: `Downloading kupcad ${release.version}`,
      },
      async (progress) => {
        let shown = 0;
        return this.#options.install(release, {
          get,
          dir: managedDir,
          platform: process.platform,
          arch: process.arch,
          progress: (received, total) => {
            if (!total) return;
            const done = Math.floor((received / total) * PERCENT);
            progress.report({ increment: done - shown });
            shown = done;
          },
        });
      },
    );
  }

  /** The releases the channel takes: pre-releases too on `prerelease`. */
  #channel() {
    return { prerelease: this.#options.settings().get('binary.channel') === 'prerelease' };
  }

  /** @param {string} why */
  async #tellBadSetting(why) {
    const chosen = await vscode.window.showErrorMessage(
      `KupCAD can't start: ${why}.`,
      OPEN_SETTINGS,
    );
    if (chosen === OPEN_SETTINGS) await this.#openSettings();
  }

  async #openSettings() {
    await vscode.commands.executeCommand('workbench.action.openSettings', 'kupcad.serverPath');
  }

  /** @param {string} why */
  async #tellNotInstalled(why) {
    const chosen = await vscode.window.showErrorMessage(
      `KupCAD needs the kupcad executable, which couldn't be installed (${why}). Install it from the releases page, or set "kupcad.serverPath".`,
      OPEN_RELEASES,
      OPEN_SETTINGS,
    );
    if (chosen === OPEN_RELEASES) await vscode.env.openExternal(vscode.Uri.parse(RELEASES_PAGE));
    if (chosen === OPEN_SETTINGS) await this.#openSettings();
  }
}
