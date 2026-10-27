// The hooks the smoke page gives the test.

import type { Section, View, Projection } from '../src/viewer/types.js';

declare global {
  interface Window {
    ready: boolean;
    smoke: {
      /** Shows the core's preview of `source`. */
      show(source: string): Promise<void>;
      setCamera(camera: { view?: View; projection?: Projection }): void;
      /** The viewer's named view, or null. */
      view(): View | null;
      setSection(section: Section | null): void;
      /** The colour drawn at (x, y), as fractions of the canvas from its top left. */
      pixel(x: number, y: number): Promise<[number, number, number]>;
    };
  }
}
