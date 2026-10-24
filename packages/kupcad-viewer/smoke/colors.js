// The colours the smoke page draws with, which the test looks for.

export const BACKGROUND = '#ffffff';
/** BACKGROUND as the red, green and blue a pixel of it reads. */
export const BACKGROUND_RGB = [1, 3, 5].map((at) =>
  Number.parseInt(BACKGROUND.slice(at, at + 2), 16),
);
/** The section's cap: pure green, which no lit red part comes near. */
export const CAP = '#00c000';
