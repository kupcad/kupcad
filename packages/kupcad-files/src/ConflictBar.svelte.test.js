import { fireEvent, render, screen } from '@testing-library/svelte';
import { expect, it, vi } from 'vitest';
import ConflictBar from './ConflictBar.svelte';

it('offers the other text, or the deletion, and keeping mine', async () => {
  const onresolve = vi.fn();
  const { rerender } = render(ConflictBar, {
    props: { name: 'lid.kup', conflict: 'cube(2)\n', where: 'on disk', onresolve },
  });
  expect(screen.getByRole('alert').textContent).toContain('lid.kup changed on disk.');
  await fireEvent.click(screen.getByRole('button', { name: 'Take theirs' }));
  await fireEvent.click(screen.getByRole('button', { name: 'Keep mine' }));
  expect(onresolve.mock.calls).toEqual([['disk'], ['mine']]);
  await rerender({ name: 'lid.kup', conflict: null, where: 'in another tab', onresolve });
  expect(screen.getByRole('alert').textContent).toContain('lid.kup was deleted in another tab.');
  await fireEvent.click(screen.getByRole('button', { name: 'Discard mine' }));
  expect(onresolve).toHaveBeenLastCalledWith('disk');
});
