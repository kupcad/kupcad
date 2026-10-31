import { describe, expect, it, vi } from 'vitest';
import { clashQuestion, freeName, putFiles, refuseStrayDrop } from './drop.js';

/** @import { Clash } from './drop.js' */

/** A folder's files on a stand-in disk, and a host over it. @param {string[]} [there] */
function hostOn(there = []) {
  const disk = new Map(there.map((path) => [path, new Uint8Array()]));
  return {
    disk,
    host: {
      exists: async (/** @type {string} */ path) => disk.has(path),
      write: vi.fn(
        async (/** @type {string} */ path, /** @type {Uint8Array<ArrayBuffer>} */ bytes) => {
          disk.set(path, bytes);
        },
      ),
      /** @type {import('vitest').Mock<(name: string, renamed: string) => Clash>} */
      clash: vi.fn(() => /** @type {Clash} */ ('cancel')),
    },
  };
}

const text = (/** @type {Uint8Array | undefined} */ bytes) => new TextDecoder().decode(bytes);

describe('files given to a folder', () => {
  it('are written in it by their names, as they are', async () => {
    const { disk, host } = hostOn();
    const files = [new File(['cube(1)\n'], 'lid.kup'), new File(['{"w": 3}'], 'sizes.json')];
    expect(await putFiles(files, '/w/parts', host)).toEqual({
      put: ['/w/parts/lid.kup', '/w/parts/sizes.json'],
      refused: [],
      cancelled: false,
    });
    expect(text(disk.get('/w/parts/lid.kup'))).toBe('cube(1)\n');
    expect(text(disk.get('/w/parts/sizes.json'))).toBe('{"w": 3}');
  });

  it("leave out what the tree wouldn't show: no script, nor a file a script reads, a hidden one", async () => {
    const { host } = hostOn();
    const files = ['notes.txt', 'photo.png', '.hidden.kup', 'parts'].map(
      (name) => new File([], name),
    );
    expect(await putFiles(files, '/', host)).toEqual({
      put: [],
      refused: ['notes.txt', 'photo.png', '.hidden.kup', 'parts'],
      cancelled: false,
    });
    expect(host.write).not.toHaveBeenCalled();
  });

  it('replace one of the same name, or take a free name, as the person says', async () => {
    const { disk, host } = hostOn(['/a.kup', '/b.kup', '/b 2.kup']);
    host.clash.mockImplementation((name) => (name === 'a.kup' ? 'replace' : 'rename'));
    const files = [new File(['mine'], 'a.kup'), new File(['theirs'], 'b.kup')];
    expect(await putFiles(files, '/', host)).toEqual({
      put: ['/a.kup', '/b 3.kup'],
      refused: [],
      cancelled: false,
    });
    // Asked with the name it would take
    expect(host.clash.mock.calls).toEqual([
      ['a.kup', 'a 2.kup'],
      ['b.kup', 'b 3.kup'],
    ]);
    expect([text(disk.get('/a.kup')), text(disk.get('/b 3.kup'))]).toEqual(['mine', 'theirs']);
  });

  it('are none of them put once the person cancels, though asked after the first', async () => {
    const { host } = hostOn(['/b.kup']);
    const files = [new File(['new'], 'a.kup'), new File(['mine'], 'b.kup')];
    expect(await putFiles(files, '/', host)).toEqual({ put: [], refused: [], cancelled: true });
    expect(host.write).not.toHaveBeenCalled();
  });
});

it('asks of a name the folder has, naming the folder and the name yours would take, Rename focused', () => {
  const question = clashQuestion('lid.kup', 'lid 2.kup', 'parts');
  expect([question.title, question.text]).toEqual([
    '“lid.kup” is in parts already',
    'Replace it with yours, or add yours as “lid 2.kup”?',
  ]);
  expect(question.answers.map(({ value }) => value)).toEqual(['cancel', 'replace', 'rename']);
  expect(question.answers.find((answer) => 'primary' in answer)?.value).toBe('rename');
  expect(question.cancel).toBe('cancel');
});

/** Free where `taken` hasn't it. @param {string[]} taken */
const freeOf = (taken) => async (/** @type {string} */ name) => !taken.includes(name);

describe('a free name, as a file manager keeps both', () => {
  it("numbers the stem from 2, past the names taken, a numbered one's from its number", async () => {
    expect(await freeName('lid.kup', freeOf([]))).toBe('lid 2.kup');
    expect(await freeName('lid.kup', freeOf(['lid 2.kup', 'lid 3.kup']))).toBe('lid 4.kup');
    expect(await freeName('lid 2.kup', freeOf([]))).toBe('lid 3.kup');
    expect(await freeName('part.v2.stl', freeOf([]))).toBe('part.v2 2.stl');
  });
});

/** A drag event carrying `types`, its default prevented already or not. */
function dragOf(/** @type {string[]} */ types, prevented = false) {
  const event = new Event('dragover', { cancelable: true });
  if (prevented) event.preventDefault();
  const drag = Object.assign(event, { dataTransfer: { types, dropEffect: 'copy' } });
  return /** @type {DragEvent & typeof drag} */ (/** @type {unknown} */ (drag));
}

describe('a drag of files nothing on the page took', () => {
  it('is refused: dropped, the browser would open the file in the page', () => {
    const event = dragOf(['Files']);
    refuseStrayDrop(event);
    expect([event.defaultPrevented, event.dataTransfer.dropEffect]).toEqual([true, 'none']);
  });

  it('is left alone where something took it, and a drag of text is too', () => {
    const taken = dragOf(['Files'], true);
    refuseStrayDrop(taken);
    expect(taken.dataTransfer.dropEffect).toBe('copy');
    const words = dragOf(['text/plain']);
    refuseStrayDrop(words);
    expect(words.defaultPrevented).toBe(false);
  });
});
