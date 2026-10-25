// The kupcad the extension runs: found (resolve.js), else the newest release in the extension's
// range installed in its storage (install.js), and that install kept up to date. This is what
// the user sees of it: a download's progress, why one failed and what to do, an update to take.

import * as fs from 'node:fs/promises';
import { errorText } from '@kupcad/protocol';
import * as path from 'node:path';
import * as vscode from 'vscode';
import { sigstoreCheck, verifyAttested } from './attestation.js';
import { install as installRelease, installedVersions } from './install.js';
import { probe as probeVersion } from './probe.js';
import { newestInRange, readReleases as readReleaseList, RELEASES_PAGE } from './releases.js';
import { findServer } from './resolve.js';
import { compareVersions, parseVersion } from './versions.js';

/** @import { VersionInfo } from '@kupcad/protocol/types' */
/** @import { Release, ReleaseList } from './releases.js' */
/** @import { Found } from './resolve.js' */
/** @import { Version } from './versions.js' */

/** Looks for a newer kupcad now, and installs it (`checkForUpdates`, asked). */
export const UPDATE_CLI_COMMAND = 'kupcad.updateCli';
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
 * That a download is the release's own: attested by its release workflow, checked by Sigstore
 * against a trusted root TUF keeps in `cachePath`.
 * @param {typeof fetch} get
 * @param {string} cachePath
 */
function attestedBy(get, cachePath) {
  const check = sigstoreCheck({ cachePath });
  return (/** @type {string} */ digest, /** @type {string} */ version) =>
    verifyAttested(digest, version, { get, check });
}

/**
 * @typedef {object} ManagerOptions
 * @property {string} range the core versions the extension runs with (`kupcad.core`)
 * @property {string} managedDir where its own installs go
 * @property {string} extensionPath
 * @property {boolean} development whether the extension runs from a source checkout, where the
 *   monorepo's build is looked for
 * @property {vscode.Memento} state what it keeps between sessions
 * @property {vscode.LogOutputChannel} log
 * @property {() => vscode.WorkspaceConfiguration} settings its settings (`kupcad.*`), as they are now
 * @property {typeof fetch} [get]
 * @property {(path: string) => Promise<VersionInfo | null>} [probe]
 * @property {typeof findServer} [find]
 * @property {typeof installRelease} [install]
 * @property {(digest: string, version: string) => Promise<void>} [attest] that a download is
 *   the release's own (verifyAttested; Sigstore's trusted root kept beside the installs)
 * @property {typeof readReleaseList} [readReleases]
 * @property {() => number} [now]
 */

export class BinaryManager {
  /** @type {Required<ManagerOptions>} */
  #options;
  /** The kupcad running now, once one is. @type {Found | null} */
  #running = null;
  /** The last look for an update asked: one waits for the one under way, so two never install at once. */
  #checks = Promise.resolve(/** @type {string | null} */ (null));

  /** @param {ManagerOptions} options */
  constructor(options) {
    this.#options = {
      get: globalThis.fetch,
      probe: probeVersion,
      find: findServer,
      install: installRelease,
      readReleases: readReleaseList,
      now: Date.now,
      attest: attestedBy(
        options.get ?? globalThis.fetch,
        path.join(path.dirname(options.managedDir), 'sigstore'),
      ),
      ...options,
    };
  }

  /**
   * The kupcad to run: one found, else the newest release in range installed (its download's
   * progress shown); null when there is neither, the user told why and what to do.
   * @returns {Promise<Found | null>}
   */
  async server() {
    const { range, managedDir, extensionPath, development, probe, log } = this.#options;
    const configured = this.#options.settings().get('serverPath');
    const { found, notes } = await this.#options.find({
      configured,
      managedDir,
      extensionPath: development ? extensionPath : null,
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
      const file = await this.#install(release);
      return (this.#running = { path: file, version: release.version, source: 'managed' });
    } catch (error) {
      log.error(`kupcad couldn't be installed: ${errorText(error)}`);
      void this.#tellNotInstalled(errorText(error));
      return null;
    }
  }

  /**
   * Looks for a newer release in range of the extension's own install, once a day unless
   * `asked`: one is installed at once when asked for or with `kupcad.binary.autoUpdate`, else
   * when the user takes it. A newer release out of range says the extension needs updating
   * first.
   * @param {{ asked: boolean }} how
   * @returns {Promise<string | null>} the new install's path, for the server to run, or null
   */
  checkForUpdates(how) {
    const check = this.#checks.then(() => this.#checkForUpdates(how));
    this.#checks = check.catch(() => null);
    return check;
  }

  /**
   * Removes the extension's own installs but the one running and the newest one before it,
   * which another window may still run until it updates too. One that can't be removed (a
   * binary running on Windows) is left for the next time.
   */
  async prune() {
    const running = this.#running;
    const { managedDir, log } = this.#options;
    if (running?.source !== 'managed') return;
    const current = /** @type {Version} */ (parseVersion(running.version));
    const older = (await installedVersions(managedDir, path.basename(running.path)))
      .map((version) => ({ version, parsed: parseVersion(version) }))
      .filter((v) => v.parsed !== null && compareVersions(v.parsed, current) < 0)
      .toSorted((a, b) =>
        compareVersions(/** @type {Version} */ (b.parsed), /** @type {Version} */ (a.parsed)),
      );
    for (const { version } of older.slice(1)) {
      await fs
        .rm(path.join(managedDir, version), { recursive: true, force: true })
        .catch((error) => log.warn(`kupcad ${version} wasn't removed: ${errorText(error)}`));
    }
  }

  /** @param {{ asked: boolean }} how */
  async #checkForUpdates({ asked }) {
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
      // Asked, the user wants it: asking again would be one click too many
      const take =
        asked ||
        this.#options.settings().get('binary.autoUpdate', true) ||
        (await vscode.window.showInformationMessage(
          `kupcad ${inRange.version} is out (this is ${running.version}).`,
          UPDATE,
        )) === UPDATE;
      if (!take) return null;
      try {
        const file = await this.#install(inRange);
        this.#running = { path: file, version: inRange.version, source: 'managed' };
        return file;
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
          attest: this.#options.attest,
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
