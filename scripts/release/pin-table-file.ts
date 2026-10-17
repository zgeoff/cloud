// The pin table: every registry pin's parts, by pin id and named group, as JSON. CI checks each
// pin line against it, and every bump writes it with the pins.
export const pinTableFile = 'scripts/release/release-pins.json';
