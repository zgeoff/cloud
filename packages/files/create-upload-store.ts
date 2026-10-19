import { Database } from 'bun:sqlite';
import type { Role, Upload } from './types.ts';

interface UploadFilter {
  readonly uploader?: Role;
  readonly includeExpired: boolean;
  readonly now: Date;
}

export interface UploadStore {
  // records a new upload; its id is unique
  readonly writeUpload: (upload: Upload) => void;
  readonly findUpload: (id: string) => Upload | null;

  // the uploads, newest first, of one uploader or of every uploader, with or without the ones
  // that expired at now but the sweep has not removed yet
  readonly readUploads: (filter: UploadFilter) => readonly Upload[];
  readonly updateExpiry: (id: string, expiresAt: Date | null) => void;
  readonly removeUpload: (id: string) => void;

  // the ids of the uploads whose expiry is before now, for the sweep
  readonly readExpiredIDs: (now: Date) => readonly string[];
  readonly close: () => void;
}

// STRICT, so a wrong type fails the write instead of being stored
const schema = `CREATE TABLE IF NOT EXISTS uploads (
  id TEXT PRIMARY KEY,
  filename TEXT NOT NULL,
  content_type TEXT NOT NULL,
  size INTEGER NOT NULL,
  sha256 TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  uploader TEXT NOT NULL CHECK (uploader IN ('agent', 'owner')),
  label TEXT,
  link TEXT,
  expires_at INTEGER
) STRICT`;

interface UploadRow {
  readonly id: string;
  readonly filename: string;
  readonly content_type: string;
  readonly size: number;
  readonly sha256: string;
  readonly created_at: number;
  readonly uploader: Role;
  readonly label: string | null;
  readonly link: string | null;
  readonly expires_at: number | null;
}

// The metadata file on the volume beside the files: one row per upload, with times in
// milliseconds since the epoch. WAL mode lets the backup's sqlite3 copy it while the service
// writes.
export function createUploadStore(path: string): UploadStore {
  const db = new Database(path, { create: true, strict: true });

  db.run('PRAGMA journal_mode = WAL');
  db.run('PRAGMA busy_timeout = 5000');
  db.run(schema);

  const insert = db.query(`INSERT INTO uploads
    (id, filename, content_type, size, sha256, created_at, uploader, label, link, expires_at)
    VALUES ($id, $filename, $contentType, $size, $sha256, $createdAt, $uploader, $label, $link,
      $expiresAt)`);

  const select = db.query<UploadRow, [string]>('SELECT * FROM uploads WHERE id = ?1');

  const selectExpired = db.query<{ id: string }, [number]>(
    'SELECT id FROM uploads WHERE expires_at < ?1 ORDER BY expires_at, id',
  );

  const updateExpiry = db.query('UPDATE uploads SET expires_at = ?2 WHERE id = ?1');
  const remove = db.query('DELETE FROM uploads WHERE id = ?1');

  return {
    writeUpload: (upload) => {
      insert.run({
        id: upload.id,
        filename: upload.filename,
        contentType: upload.contentType,
        size: upload.size,
        sha256: upload.sha256,
        createdAt: upload.createdAt.getTime(),
        uploader: upload.uploader,
        label: upload.label,
        link: upload.link,
        expiresAt: upload.expiresAt?.getTime() ?? null,
      });
    },
    findUpload: (id) => {
      const row = select.get(id);

      return row === null ? null : toUpload(row);
    },
    readUploads: (filter) => readUploads(db, filter),
    updateExpiry: (id, expiresAt) => {
      updateExpiry.run(id, expiresAt?.getTime() ?? null);
    },
    removeUpload: (id) => {
      remove.run(id);
    },
    readExpiredIDs: (now) => selectExpired.all(now.getTime()).map((row) => row.id),
    close: () => {
      db.close();
    },
  };
}

function toUpload(row: UploadRow): Upload {
  return {
    id: row.id,
    filename: row.filename,
    contentType: row.content_type,
    size: row.size,
    sha256: row.sha256,
    createdAt: new Date(row.created_at),
    uploader: row.uploader,
    label: row.label,
    link: row.link,
    expiresAt: row.expires_at === null ? null : new Date(row.expires_at),
  };
}

// id breaks a tie between two uploads made in the same millisecond
function readUploads(db: Database, filter: UploadFilter): readonly Upload[] {
  const includeExpired = filter.includeExpired ? 1 : 0;

  const rows = db
    .query<UploadRow, [Role | null, number, number]>(
      `SELECT * FROM uploads
      WHERE (?1 IS NULL OR uploader = ?1)
        AND (?2 = 1 OR expires_at IS NULL OR expires_at > ?3)
      ORDER BY created_at DESC, id DESC`,
    )
    .all(filter.uploader ?? null, includeExpired, filter.now.getTime());

  return rows.map((row) => toUpload(row));
}
