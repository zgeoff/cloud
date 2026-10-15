// The part of impd's record of an imp that the slot and idle rules read
export interface ImpActivity {
  readonly name: string;
  readonly state: 'creating' | 'running' | 'sleeping' | 'stopped' | 'error';

  // when impd last saw the imp in use; null before its first use
  readonly lastActiveAt: Date | null;
}

// The previews to put to sleep before the opening one runs, so that at most `slots` previews run
// at once. A running imp holds a slot. The least recently active previews go first,
// and the opening preview never goes, since it is the one taking a slot.
export function planSlotEvictions(
  imps: readonly ImpActivity[],
  slots: number,
  opening: string,
): string[] {
  const live = imps
    .filter((imp) => imp.name !== opening && imp.state === 'running')
    .toSorted((a, b) => (a.lastActiveAt?.getTime() ?? 0) - (b.lastActiveAt?.getTime() ?? 0));

  return live.slice(0, Math.max(0, live.length - (slots - 1))).map((imp) => imp.name);
}
