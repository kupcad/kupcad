// What an error says, for a person: the host's messages and logs, and the page's problems.

/**
 * An Error's message, else the thing thrown itself.
 * @param {unknown} error
 * @returns {string}
 */
export const errorText = (error) => (error instanceof Error ? error.message : String(error));
