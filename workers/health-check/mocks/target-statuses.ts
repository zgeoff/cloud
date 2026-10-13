// The status each probe target answers, by the URL the worker probes. A test stores the
// status its target answers; the preload clears it after each test.
export const targetStatuses = new Map<string, number>();
