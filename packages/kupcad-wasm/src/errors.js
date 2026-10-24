// What a call can fail with besides a JavaScript error.

/** The core refused: a script that doesn't parse or run, values it refused, a format it lacks. */
export class KupcadError extends Error {
  /** @param {string} message the core's, as get_last_error gives it */
  constructor(message) {
    super(message);
    this.name = 'KupcadError';
  }
}

/**
 * The module stopped (a trap, or an exit): its instance can't be used again. A worker's is
 * replaced on the next call; a module's own is made anew with `createKupcad`.
 */
export class KupcadCrashError extends Error {
  /**
   * @param {string} message
   * @param {{ cause?: unknown }} [options]
   */
  constructor(message, options) {
    super(message, options);
    this.name = 'KupcadCrashError';
  }
}
