import { fireEvent, render, screen } from '@testing-library/svelte';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import Splitter from './Splitter.svelte';

// jsdom captures no pointer: the bar takes the drag as a browser gives it, the moves its own
const capture = HTMLElement.prototype.setPointerCapture;
beforeEach(() => {
  HTMLElement.prototype.setPointerCapture = () => {};
});
afterEach(() => {
  HTMLElement.prototype.setPointerCapture = capture;
});

/**
 * A bar sizing a pane of `size`, and the sizes it gave once a move was done.
 * @param {Partial<import('svelte').ComponentProps<typeof Splitter>>} [props]
 */
function bar(props = {}) {
  const onchange = vi.fn();
  render(Splitter, { props: { size: 300, label: 'Resize the editor', onchange, ...props } });
  const separator = screen.getByRole('separator', { name: 'Resize the editor' });
  return { separator, onchange, size: () => Number(separator.getAttribute('aria-valuenow')) };
}

describe('Splitter', () => {
  it('resizes the pane before it with the arrow keys, Shift for longer steps, Home and End', async () => {
    const { separator, onchange, size } = bar({ min: 200, max: 600 });
    expect(separator.getAttribute('aria-orientation')).toBe('vertical');
    await fireEvent.keyDown(separator, { key: 'ArrowRight' });
    expect(size()).toBe(316);
    await fireEvent.keyDown(separator, { key: 'ArrowLeft', shiftKey: true });
    expect(size()).toBe(252);
    await fireEvent.keyDown(separator, { key: 'Home' });
    expect(size()).toBe(200);
    await fireEvent.keyDown(separator, { key: 'End' });
    expect(size()).toBe(600);
    expect(onchange.mock.calls.map(([given]) => given)).toEqual([316, 252, 200, 600]);
  });

  it('grows the pane after it as the bar moves toward its start, between rows by Up and Down', async () => {
    const { separator, size } = bar({ between: 'rows', pane: 'after' });
    expect(separator.getAttribute('aria-orientation')).toBe('horizontal');
    await fireEvent.keyDown(separator, { key: 'ArrowUp' });
    expect(size()).toBe(316);
    await fireEvent.keyDown(separator, { key: 'ArrowLeft' });
    expect(size()).toBe(316);
  });

  it('follows a drag within its bounds, gives the size once it is done, and goes back on a double click', async () => {
    const { separator, onchange, size } = bar({ min: 200, max: 400 });
    await fireEvent.pointerDown(separator, { button: 0, clientX: 500, pointerId: 1 });
    await fireEvent.pointerMove(separator, { clientX: 550, pointerId: 1 });
    expect(size()).toBe(350);
    await fireEvent.pointerMove(separator, { clientX: 900, pointerId: 1 });
    expect(size()).toBe(400);
    expect(onchange).not.toHaveBeenCalled();
    await fireEvent.pointerUp(separator, { pointerId: 1 });
    expect(onchange).toHaveBeenCalledWith(400);
    await fireEvent.dblClick(separator);
    expect(size()).toBe(300);
    expect(onchange).toHaveBeenLastCalledWith(300);
  });
});
