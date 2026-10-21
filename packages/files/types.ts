// all agents share the agent token
export type Role = 'agent' | 'owner';

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
