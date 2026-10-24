import { fireEvent, render, screen, within } from '@testing-library/svelte';
import { describe, expect, it } from 'vitest';
import { BRACKET, schemaOf } from './fixtures.test-helper.js';
import ParamsPanel from './ParamsPanel.svelte';

/** @import { ParamValues } from '@kupcad/protocol/types' */

/**
 * The panel of the bracket's schema, and every change it gives.
 * @param {object} [props]
 */
async function panel(props = {}) {
  /** @type {ParamValues[]} */
  const changes = [];
  render(ParamsPanel, {
    props: {
      schema: await schemaOf(BRACKET),
      values: { width: 25, height: 5, hollow: false, label: 'A', size: 'm4' },
      onchange: (/** @type {ParamValues} */ overrides) => changes.push(overrides),
      ...props,
    },
  });
  return changes;
}

/** @param {string} name */
const numberField = (name) => /** @type {HTMLInputElement} */ (screen.getByLabelText(name));

describe('ParamsPanel', () => {
  it("shows the script's title, and each group's controls with the values the run took", async () => {
    await panel();
    expect(screen.getByRole('heading', { name: 'Bracket' })).toBeTruthy();
    expect(screen.getByText('A plate with holes')).toBeTruthy();
    const legends = [...document.querySelectorAll('legend')].map((legend) => legend.textContent);
    expect(legends).toEqual(['Size', 'Holes']);
    expect(numberField('width').value).toBe('25');
    expect(screen.getByRole('slider', { name: 'width slider' })).toBeTruthy();
    expect(screen.getByRole('checkbox', { name: 'hollow' })).toBeTruthy();
    expect(
      /** @type {HTMLSelectElement} */ (screen.getByLabelText('size')).selectedOptions[0]
        .textContent,
    ).toBe('m4');
  });

  it('gives a value the script takes, marks it set, and takes it back on revert', async () => {
    const changes = await panel();
    await fireEvent.change(numberField('width'), { target: { value: '40' } });
    expect(changes).toEqual([{ width: 40 }]);
    await fireEvent.click(screen.getByRole('button', { name: 'Revert width' }));
    expect(changes).toEqual([{ width: 40 }, {}]);
    expect(screen.queryByRole('button', { name: 'Revert width' })).toBeNull();
  });

  it("refuses a value outside the script's range, saying why on the control, and gives nothing", async () => {
    const changes = await panel();
    await fireEvent.change(numberField('width'), { target: { value: '5' } });
    const alert = screen.getByRole('alert');
    expect(alert.textContent).toBe('must be at least 10');
    expect(changes).toEqual([]);
    expect(numberField('width').getAttribute('aria-invalid')).toBe('true');
    expect(numberField('width').getAttribute('aria-describedby')).toBe(alert.id);
  });

  it('takes the refusal away with the value it was given for: a revert', async () => {
    await panel();
    await fireEvent.change(numberField('width'), { target: { value: '40' } });
    await fireEvent.change(numberField('width'), { target: { value: '5' } });
    expect(screen.getByRole('alert')).toBeTruthy();
    await fireEvent.click(screen.getByRole('button', { name: 'Revert width' }));
    expect(screen.queryByRole('alert')).toBeNull();
    expect(numberField('width').hasAttribute('aria-invalid')).toBe(false);
  });

  it('shows no choice for a parameter without one yet, until one is chosen', async () => {
    /** @type {ParamValues[]} */
    const changes = [];
    const source =
      'k = :m4\nsize = param(:size, default: k, validate: { in: [:m3, :m4] })\ncube(1)\n';
    render(ParamsPanel, {
      props: { schema: await schemaOf(source), onchange: (overrides) => changes.push(overrides) },
    });
    const size = /** @type {HTMLSelectElement} */ (screen.getByLabelText('size'));
    expect(size.selectedOptions[0].textContent).toBe('');
    await fireEvent.change(size, { target: { value: '0' } });
    expect(changes).toEqual([{ size: 'm3' }]);
  });

  it('gives a listed choice as listed, and a toggle as a boolean', async () => {
    const changes = await panel();
    const size = /** @type {HTMLSelectElement} */ (screen.getByLabelText('size'));
    const m5 = [...size.options].findIndex((option) => option.textContent === 'm5');
    await fireEvent.change(size, { target: { value: String(m5) } });
    await fireEvent.click(screen.getByRole('checkbox', { name: 'hollow' }));
    expect(changes).toEqual([{ size: 'm5' }, { size: 'm5', hollow: true }]);
  });

  it('shows why the run refused a value on its control', async () => {
    await panel({
      error: { message: 'ValueError: too wide', line: 3, column: 5, param: 'width' },
    });
    const field = /** @type {HTMLElement} */ (numberField('width').closest('.field'));
    expect(within(field).getByRole('alert').textContent).toBe('ValueError: too wide');
  });

  it('says so of a script without parameters', async () => {
    render(ParamsPanel, { props: { schema: await schemaOf('cube(1)') } });
    expect(screen.getByText('This script has no parameters.')).toBeTruthy();
  });
});
