// How the viewer looks, as the person chose it, kept in a host's settings under the view.* keys:
// the render mode, the edges and the axes shown, the floor (environment) and the projection.
// ViewerPane reads each in a $derived and writes what the person chooses; a host's settings page
// shows and writes the same keys, and the pane follows it. A kept value that isn't one reads as
// the default.

import { RENDER_MODES } from './viewer/index.js';

/** @import { Settings } from './settings.js' */
/** @import { Environment, Projection, RenderMode } from './viewer/types.js' */

/**
 * The view as chosen.
 * @typedef {object} ViewChoices
 * @property {RenderMode} renderMode
 * @property {boolean} edges
 * @property {boolean} axes
 * @property {Environment} environment the floor: a grid, the build plate, or none
 * @property {Projection} projection
 */

/** The settings' keys, by choice. @type {Readonly<Record<keyof ViewChoices, string>>} */
export const VIEW_KEYS = Object.freeze({
  renderMode: 'view.renderMode',
  edges: 'view.edges',
  axes: 'view.axes',
  environment: 'view.environment',
  projection: 'view.projection',
});

/** The floors the viewer stands a model on, in the order a settings page offers them. */
export const ENVIRONMENTS = /** @type {const} */ (['grid', 'plate', 'none']);

/** The projections, in the order a settings page offers them. */
export const PROJECTIONS = /** @type {const} */ (['perspective', 'orthographic']);

/** What the view is before anyone chose. @type {Readonly<ViewChoices>} */
export const VIEW_DEFAULTS = Object.freeze({
  renderMode: 'solid',
  edges: true,
  axes: true,
  environment: 'grid',
  projection: 'perspective',
});

/** The values each choice takes. @type {Record<keyof ViewChoices, readonly unknown[]>} */
const VALID = {
  renderMode: RENDER_MODES,
  edges: [true, false],
  axes: [true, false],
  environment: ENVIRONMENTS,
  projection: PROJECTIONS,
};

/**
 * The view's `name` as `settings` keep it, else its default. Read in a reaction, it reads that
 * key alone.
 * @template {keyof ViewChoices} K
 * @param {Settings} settings
 * @param {K} name
 * @returns {ViewChoices[K]}
 */
export function viewChoice(settings, name) {
  const kept = settings.get(VIEW_KEYS[name]);
  return /** @type {ViewChoices[K]} */ (VALID[name].includes(kept) ? kept : VIEW_DEFAULTS[name]);
}

/**
 * The whole view as `settings` keep it, each choice else its default.
 * @param {Settings} settings
 * @returns {ViewChoices}
 */
export function viewChoices(settings) {
  return {
    renderMode: viewChoice(settings, 'renderMode'),
    edges: viewChoice(settings, 'edges'),
    axes: viewChoice(settings, 'axes'),
    environment: viewChoice(settings, 'environment'),
    projection: viewChoice(settings, 'projection'),
  };
}
