import { beforeEach, describe, expect, it, vi } from 'vitest';
import { EXPORT_COMMAND, registerExportCommands } from './commands.js';
import { BuildError } from './export.js';
// The module Vitest gives the code as `vscode`
import { commands, documentAt, fake, resetFake, Uri, window } from './testing/vscode.js';
import { ScriptValues } from './values.js';

const PART_URI = 'file:///work/part.kup';

/**
 * The commands registered, with the kupcad given running, and the builds they ran.
 * @param {{ kupcad?: string | null, shown?: string | null, fails?: string }} [world]
 */
function registered(world = {}) {
  /** @type {{ kupcad: string, args: string[], cwd: string }[]} */
  const builds = [];
  const values = new ScriptValues();
  registerExportCommands({
    kupcad: () => (world.kupcad === undefined ? '/usr/local/bin/kupcad' : world.kupcad),
    values,
    shown: () => world.shown ?? null,
    log: /** @type {any} */ (window.createOutputChannel()),
    build: async (kupcad, args, { cwd, signal }) => {
      builds.push({ kupcad, args, cwd });
      if (world.fails === 'slowly') {
        await new Promise((_, reject) =>
          signal?.addEventListener('abort', () => reject(new Error('aborted'))),
        );
      }
      if (world.fails) throw new BuildError(world.fails);
    },
  });
  return { builds, values };
}

beforeEach(() => resetFake());

describe('export', () => {
  it("builds the editor's script with its values to the file and format the user picks", async () => {
    fake.activeDocument = documentAt('/work/part.kup');
    const { builds, values } = registered();
    values.set(PART_URI, { width: 40 });
    fake.pick = '3MF';
    fake.saveAnswer = Uri.file('/out/part.3mf');
    fake.answer = 'Reveal';
    /** @type {unknown[]} */
    const revealed = [];
    commands.registerCommand('revealFileInOS', (/** @type {unknown} */ uri) => revealed.push(uri));
    await commands.executeCommand(EXPORT_COMMAND);
    expect(fake.picks[0]).toEqual(['STL', '3MF', 'STEP', 'GLB', 'glTF', 'OBJ', 'SVG', 'DXF']);
    expect(builds).toEqual([
      {
        kupcad: '/usr/local/bin/kupcad',
        args: ['build', '/work/part.kup', '-o', '/out/part.3mf', '-f', '3mf', '-p', 'width=40'],
        cwd: '/work',
      },
    ]);
    expect(fake.progress[0]).toMatchObject({ title: 'Exporting part as 3MF', cancellable: true });
    expect(fake.messages[0]).toEqual({
      level: 'information',
      text: 'Exported part.3mf.',
      buttons: ['Reveal'],
      modal: false,
    });
    expect(revealed).toHaveLength(1);
  });

  it('builds the script the viewer shows, or the one given, and nothing the user dismisses', async () => {
    documentAt('/work/lid.kup');
    const { builds } = registered({ shown: 'file:///work/lid.kup' });
    fake.pick = 'STL';
    fake.saveAnswer = Uri.file('/out/lid.stl');
    await commands.executeCommand(EXPORT_COMMAND);
    expect(builds[0].args[1]).toBe('/work/lid.kup');
    await commands.executeCommand(EXPORT_COMMAND, PART_URI);
    expect(builds[1].args[1]).toBe('/work/part.kup');

    fake.pick = undefined;
    await commands.executeCommand(EXPORT_COMMAND, PART_URI);
    fake.pick = 'STL';
    fake.saveAnswer = undefined;
    await commands.executeCommand(EXPORT_COMMAND, PART_URI);
    expect(builds).toHaveLength(2);
  });

  it("builds the script the editor's title bar gives, as a Uri", async () => {
    documentAt('/work/lid.kup');
    const { builds } = registered();
    fake.pick = 'STEP';
    fake.saveAnswer = Uri.file('/out/lid');
    await commands.executeCommand(EXPORT_COMMAND, Uri.file('/work/lid.kup'));
    expect(builds[0].args.slice(1, 6)).toEqual(['/work/lid.kup', '-o', '/out/lid', '-f', 'step']);
  });

  it('saves a script with changes first, when the user says so, and builds nothing left unsaved', async () => {
    const part = documentAt('/work/part.kup');
    part.isDirty = true;
    fake.activeDocument = part;
    const { builds } = registered();
    fake.pick = 'STL';
    fake.saveAnswer = Uri.file('/out/part.stl');
    await commands.executeCommand(EXPORT_COMMAND);
    expect(builds).toHaveLength(0);
    expect(fake.messages[0]).toMatchObject({ level: 'warning', buttons: ['Save'], modal: true });
    fake.answer = 'Save';
    await commands.executeCommand(EXPORT_COMMAND);
    expect(part.saves).toBe(1);
    expect(builds).toHaveLength(1);
  });

  it('says why a build failed, and nothing of one the user stopped', async () => {
    fake.activeDocument = documentAt('/work/part.kup');
    registered({ fails: 'error(vm): RuntimeError: boom' });
    fake.pick = 'STL';
    fake.saveAnswer = Uri.file('/out/part.stl');
    await commands.executeCommand(EXPORT_COMMAND);
    expect(fake.messages[0]).toMatchObject({
      level: 'error',
      text: "part couldn't be built: error(vm): RuntimeError: boom",
    });

    resetFake();
    fake.activeDocument = documentAt('/work/part.kup');
    registered({ fails: 'slowly' });
    fake.pick = 'STL';
    fake.saveAnswer = Uri.file('/out/part.stl');
    const running = commands.executeCommand(EXPORT_COMMAND);
    await vi.waitFor(() => expect(fake.cancellations).toHaveLength(1));
    fake.cancelProgress();
    await running;
    expect(fake.messages).toEqual([]);
  });

  it('says what is missing: a script, a saved file, a kupcad to build with', async () => {
    registered();
    await commands.executeCommand(EXPORT_COMMAND);
    expect(fake.messages[0].text).toBe('Open a KupCAD script to build it.');

    fake.activeDocument = documentAt('/Untitled-1', 'kupcad', 'untitled');
    await commands.executeCommand(EXPORT_COMMAND);
    expect(fake.messages[1].text).toBe('Save Untitled-1 to a file first: kupcad builds files.');

    resetFake();
    registered({ kupcad: null });
    fake.activeDocument = documentAt('/work/part.kup');
    await commands.executeCommand(EXPORT_COMMAND);
    expect(fake.messages[0].text).toMatch(/isn't running/);
    expect(fake.picks).toEqual([]);
  });
});
