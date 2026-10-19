// a full volume or quota from the filesystem, or a full database from SQLite
const storageFullCodes: ReadonlySet<string> = new Set(['ENOSPC', 'EDQUOT', 'SQLITE_FULL']);

// Whether a write failed because the volume has no room left, as opposed to any other failure.
export function isStorageFullError(error: unknown): boolean {
  return (
    error instanceof Error &&
    'code' in error &&
    typeof error.code === 'string' &&
    storageFullCodes.has(error.code)
  );
}
