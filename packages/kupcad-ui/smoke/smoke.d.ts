// The hooks the smoke page gives the test, and Vite's types (the pane's page imports CSS).

/// <reference types="vite/client" />

import type { Environment, Section, View, Projection } from '../src/viewer/types.js';

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
      setEnvironment(environment: Environment): void;
      /** The colour drawn at (x, y), as fractions of the canvas from its top left. */
      pixel(x: number, y: number): Promise<[number, number, number]>;
      /** Every colour drawn from (x0, y0) to (x1, y1), as fractions of the canvas, row by row. */
      pixels(x0: number, y0: number, x1: number, y1: number): Promise<[number, number, number][]>;
    };
  }
}
