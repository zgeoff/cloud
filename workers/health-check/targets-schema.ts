import { z } from 'zod/mini';

// The TARGETS binding's value once JSON-parsed: each target's name, which keys its state, and the
// URL the check probes
export const targetsSchema = z.array(z.object({ name: z.string(), url: z.string() }));

export type Target = z.infer<typeof targetsSchema>[number];
