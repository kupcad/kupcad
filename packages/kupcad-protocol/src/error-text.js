// What an error says, for a person: a host's messages and logs, a page's notices.

/**
 * An Error's message, else the thing thrown itself.
 * @param {unknown} error
 * @returns {string}
 */
export const errorText = (error) => (error instanceof Error ? error.message : String(error));
