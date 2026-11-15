import { z } from 'zod';

const tokenRequestSchema = z.object({
  status: z.object({ token: z.string().min(1), expirationTimestamp: z.string().min(1) }),
});

export interface MintedToken {
  readonly token: string;
  readonly expiresAt: string;
}

// The answer of `kubectl create token --output json`, a TokenRequest.
export function parseTokenRequest(text: string): MintedToken | null {
  const parsed = tokenRequestSchema.safeParse(parseJSON(text));

  return parsed.success
    ? { token: parsed.data.status.token, expiresAt: parsed.data.status.expirationTimestamp }
    : null;
}

function parseJSON(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}
