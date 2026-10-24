import { beforeEach, describe, expect, it } from 'vitest';
import { PresetsFile } from './presets-file.js';
import { PresetsError, writePresets } from './presets.js';
// The module Vitest gives the code as `vscode`
import { fake, resetFake, Uri } from './testing/vscode.js';

const PRESETS = '/work/part.presets.json';

/**
 * The presets file of the script at `uri` (the stand-in's Uri is what it uses of VS Code's).
 * @param {string} uri
 */
const presetsOf = (uri) => new PresetsFile(/** @type {any} */ (Uri.parse(uri)));

/** @param {string} text the presets file's */
const onDisk = (text) => fake.files.set(PRESETS, new TextEncoder().encode(text));

beforeEach(() => resetFake());

describe('PresetsFile', () => {
  it("is the script's, beside it, in the script's scheme", () => {
    const file = presetsOf('file:///work/part.kup');
    expect(file.uri.toString()).toBe('file:///work/part.presets.json');
    expect(file.name).toBe('part.presets.json');
    const remote = presetsOf('vscode-remote://ssh-host/home/a/lid.kup');
    expect(remote.uri.toString()).toBe('vscode-remote://ssh-host/home/a/lid.presets.json');
  });

  it('reads none without a file, and says why it reads none of a broken one', async () => {
    const file = presetsOf('file:///work/part.kup');
    expect(await file.read()).toEqual({});
    onDisk('{ "presets": [] }');
    await expect(file.read()).rejects.toBeInstanceOf(PresetsError);
  });

  it('puts a preset in the file as it is now, replacing one of its name', async () => {
    const file = presetsOf('file:///work/part.kup');
    await file.put('Small', { w: 1 });
    onDisk(writePresets({ Small: { w: 1 }, Large: { w: 9 } }));
    await file.put('Small', { w: 2 });
    expect(await file.read()).toEqual({ Small: { w: 2 }, Large: { w: 9 } });
  });

  it('hears its own file change, and none once disposed', () => {
    let heard = 0;
    const watch = presetsOf('file:///work/part.kup').watch(() => (heard += 1));
    fake.fileChanged(PRESETS);
    fake.fileChanged('/work/lid.presets.json');
    expect(heard).toBe(1);
    watch.dispose();
    fake.fileChanged(PRESETS);
    expect(heard).toBe(1);
    expect(fake.watchers).toEqual([]);
  });
});
