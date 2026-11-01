import { describe, expect, it } from 'vitest';
import { extensionOf, isScriptName, stemOf } from './names.js';

describe('names', () => {
  it('splits a name, or a path, into its stem and its extension, in any case', () => {
    expect(
      ['part.kup', 'A.KUP', 'notes.tar.gz', 'README', '.hidden', '.kup', 'a.'].map(extensionOf),
    ).toEqual(['kup', 'kup', 'gz', null, null, null, '']);
    expect(
      ['part.kup', 'A.KUP', 'notes.tar.gz', 'README', '.hidden', '/w/lid.kup', '/w.d/lid'].map(
        stemOf,
      ),
    ).toEqual(['part', 'A', 'notes.tar', 'README', '.hidden', '/w/lid', '/w.d/lid']);
    expect(['part.kup', 'A.KUP', 'part.kupx', 'kup', '/w/p.kup'].map(isScriptName)).toEqual([
      true,
      true,
      false,
      false,
      true,
    ]);
  });
});
