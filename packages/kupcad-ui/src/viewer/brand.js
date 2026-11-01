// The KupCAD brand's colours, which tokens.css paints the panels in and the viewer's theme
// paints a picked part and the edges in: one place for both, in the viewer, which any host may
// take alone (tokens.test.js holds the CSS, which can't import it, to this).

export const BRAND = Object.freeze({
  /** Orangered: the accent, a picked part. */
  orange: '#ff5f14',
  /** The text, the dark background, the edges. */
  black: '#1a1b1c',
  white: '#ffffff',
  /** Gainsboro: the surfaces, the light text on dark. */
  gainsboro: '#e3e7eb',
});
