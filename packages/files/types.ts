// The two role tokens. All agents share agent, and an upload's uploader is its token's role.
export type Role = 'agent' | 'owner';

// One upload's metadata row. The server sets every field but filename, label, link and expiresAt,
// which come from the uploader; expiresAt is null for an upload that never expires.
export interface Upload {
  readonly id: string;
  readonly filename: string;
  readonly contentType: string;
  readonly size: number;
  readonly sha256: string;
  readonly createdAt: Date;
  readonly uploader: Role;
  readonly label: string | null;
  readonly link: string | null;
  readonly expiresAt: Date | null;
}
