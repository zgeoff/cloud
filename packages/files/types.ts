// all agents share the agent token
export type Role = 'agent' | 'owner';

// filename, label, link and expiresAt come from the uploader, and the server sets the rest;
// expiresAt is null for an upload that never expires
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
