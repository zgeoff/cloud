import { z } from 'zod';
import type { Role } from './types.ts';

interface ExpiryFacts {
  // 7d, 30d, never, a date (YYYY-MM-DD, at 00:00 UTC), or a date and time with its offset
  readonly expires: string;
  readonly role: Role;
  readonly now: Date;
}

type ExpiryDecision =
  | { readonly outcome: 'allowed'; readonly expiresAt: Date | null }
  | { readonly outcome: 'invalid'; readonly reason: string }
  | { readonly outcome: 'forbidden'; readonly reason: string };

const dayMs = 24 * 60 * 60 * 1000;
const agentLimitMs = 30 * dayMs;

export function decideExpiry(facts: ExpiryFacts): ExpiryDecision {
  const expiresAt = parseExpires(facts.expires, facts.now);

  if (expiresAt === undefined || (expiresAt !== null && !Number.isFinite(expiresAt.getTime()))) {
    return {
      outcome: 'invalid',
      reason: 'expires must be 7d, 30d, never, a date, or a date and time with its offset',
    };
  }

  if (expiresAt !== null && expiresAt.getTime() <= facts.now.getTime()) {
    return { outcome: 'invalid', reason: 'expires must be in the future' };
  }

  if (facts.role === 'owner') {
    return { outcome: 'allowed', expiresAt };
  }

  if (expiresAt === null) {
    return { outcome: 'forbidden', reason: 'the agent token cannot keep a file forever' };
  }

  if (expiresAt.getTime() - facts.now.getTime() > agentLimitMs) {
    return { outcome: 'forbidden', reason: 'the agent token keeps a file 30 days at most' };
  }

  return { outcome: 'allowed', expiresAt };
}

// a Map, so a name such as toString that every object inherits names no duration
const durations: ReadonlyMap<string, number> = new Map([
  ['7d', 7],
  ['30d', 30],
]);

const dateSchema = z.iso.date();
const dateTimeSchema = z.iso.datetime({ offset: true });

// the expiry time, null for never, or undefined for text that names no time
function parseExpires(text: string, now: Date): Date | null | undefined {
  if (text === 'never') {
    return null;
  }

  const days = durations.get(text);

  if (days !== undefined) {
    return new Date(now.getTime() + days * dayMs);
  }

  if (dateSchema.safeParse(text).success) {
    return new Date(`${text}T00:00:00Z`);
  }

  return dateTimeSchema.safeParse(text).success ? new Date(text) : undefined;
}
