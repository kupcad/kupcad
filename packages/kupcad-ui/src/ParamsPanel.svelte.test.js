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
    // Each group a section under its title, foldable, its controls named by it
    const titles = [...document.querySelectorAll('details > summary')].map((t) => t.textContent);
    expect(titles).toEqual(['Size', 'Holes']);
    expect(
      within(screen.getByRole('group', { name: 'Size' })).getByLabelText('width'),
    ).toBeTruthy();
    expect(
      within(screen.getByRole('group', { name: 'Holes' })).getByLabelText('size'),
    ).toBeTruthy();
    // The parameters of no group come first, under none
    expect(screen.queryByRole('group', { name: 'hollow' })).toBeNull();
    expect(numberField('width').value).toBe('25');
    expect(screen.getByRole('slider', { name: 'width slider' })).toBeTruthy();
    expect(screen.getByRole('checkbox', { name: 'hollow' })).toBeTruthy();
    expect(
      /** @type {HTMLSelectElement} */ (screen.getByLabelText('size')).selectedOptions[0]
        .textContent,
    ).toBe('m4');
  });

  it('labels a control by its title, with its description, else by its name alone', async () => {
    await panel();
    const height = numberField('Height');
    const description = screen.getByText("The plate's thickness");
    expect(height.getAttribute('aria-describedby')).toBe(description.id);
    // The name the script reads it by, where the title hides it
    expect(screen.getByText('Height').getAttribute('title')).toBe('height');
    expect(screen.getByText('width').hasAttribute('title')).toBe(false);
    expect(numberField('width').hasAttribute('aria-describedby')).toBe(false);
    // A refusal is described too, after the description
    await fireEvent.change(height, { target: { value: '0' } });
    expect(height.getAttribute('aria-describedby')).toBe(
      `${description.id} ${screen.getByRole('alert').id}`,
    );
    await fireEvent.change(height, { target: { value: '2' } });
    await fireEvent.click(screen.getByRole('button', { name: 'Revert Height' }));
    expect(height.getAttribute('aria-describedby')).toBe(description.id);
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

  it("doesn't submit its form: Enter in a field leaves the page where it is", async () => {
    await panel();
    const form = /** @type {HTMLFormElement} */ (numberField('width').form);
    const submit = new Event('submit', { cancelable: true });
    form.dispatchEvent(submit);
    expect(submit.defaultPrevented).toBe(true);
  });

  it('says so of a script without parameters', async () => {
    render(ParamsPanel, { props: { schema: await schemaOf('cube(1)') } });
    expect(screen.getByText('This script has no parameters.')).toBeTruthy();
  });
});

/** A script with Array parameters, and one with no default. */
const LISTS = `xs = param(:xs, default: [10, 20], unit: "mm")
pts = param(:pts, default: [[0, 0], [10, 0]])
key = param(:key, title: "Key")
cube(1)
`;

/** The panel of LISTS, the values its run took, and every change it gives. */
async function lists() {
  /** @type {ParamValues[]} */
  const changes = [];
  render(ParamsPanel, {
    props: {
      schema: await schemaOf(LISTS),
      values: {
        xs: [10, 20],
        pts: [
          [0, 0],
          [10, 0],
        ],
      },
      onchange: (/** @type {ParamValues} */ overrides) => changes.push(overrides),
    },
  });
  return changes;
}

describe('ParamsPanel, of an Array parameter', () => {
  it('shows a control per element, an array in it as its JSON, and one with no value empty', async () => {
    await lists();
    const xs = screen.getByRole('list', { name: 'xs' });
    expect(within(xs).getAllByRole('listitem')).toHaveLength(2);
    expect(numberField('xs [0]').value).toBe('10');
    expect(numberField('xs [1]').value).toBe('20');
    expect(within(xs).getAllByText('mm')).toHaveLength(2);
    expect(numberField('pts [1]').value).toBe('[10,0]');
    expect(numberField('Key').value).toBe('');
  });

  it('gives the array with an element changed, removed or added', async () => {
    const changes = await lists();
    await fireEvent.change(numberField('xs [1]'), { target: { value: '25' } });
    await fireEvent.click(screen.getByRole('button', { name: 'Remove xs [0]' }));
    await fireEvent.click(screen.getByRole('button', { name: 'Add to xs' }));
    expect(changes.map((overrides) => overrides.xs)).toEqual([[10, 25], [25], [25, 25]]);
    await fireEvent.change(numberField('pts [1]'), { target: { value: '[5, 6]' } });
    expect(changes.at(-1)?.pts).toEqual([
      [0, 0],
      [5, 6],
    ]);
  });

  it("refuses an element it can't take, by its place, and gives nothing", async () => {
    const changes = await lists();
    await fireEvent.change(numberField('pts [0]'), { target: { value: '[1' } });
    expect(screen.getByRole('alert').textContent).toBe('[0] must be an array, as [10, 20]');
    expect(numberField('pts [0]').getAttribute('aria-invalid')).toBe('true');
    expect(changes).toEqual([]);
  });
});
