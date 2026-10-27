import { describe, expect, it } from 'vitest';
import { memorySettings } from './settings.js';
import { VIEW_DEFAULTS, VIEW_KEYS, viewChoice, viewChoices } from './view-settings.js';

describe('view choices', () => {
  it('are the defaults before anyone chose', () => {
    expect(viewChoices(memorySettings())).toEqual({
      renderMode: 'solid',
      edges: true,
      axes: true,
      environment: 'grid',
      projection: 'perspective',
    });
    expect(viewChoices(memorySettings())).toEqual(VIEW_DEFAULTS);
  });

  it('read what the settings keep under the view.* keys', () => {
    const settings = memorySettings({
      'view.renderMode': 'xray',
      'view.edges': false,
      'view.axes': false,
      'view.environment': 'plate',
      'view.projection': 'orthographic',
    });
    expect(viewChoices(settings)).toEqual({
      renderMode: 'xray',
      edges: false,
      axes: false,
      environment: 'plate',
      projection: 'orthographic',
    });
    expect(Object.values(VIEW_KEYS)).toEqual([
      'view.renderMode',
      'view.edges',
      'view.axes',
      'view.environment',
      'view.projection',
    ]);
  });

  it("read what isn't one of a choice's values as its default", () => {
    const settings = memorySettings({
      'view.renderMode': 'sketchy',
      'view.edges': 'yes',
      'view.axes': 0,
      'view.environment': null,
      'view.projection': 'fisheye',
    });
    expect(viewChoices(settings)).toEqual(VIEW_DEFAULTS);
    expect(viewChoice(settings, 'projection')).toBe('perspective');
  });
});
