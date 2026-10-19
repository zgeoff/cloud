import { z } from 'zod/mini';

export const targetsSchema = z.array(z.object({ name: z.string(), url: z.string() }));

export type Target = z.infer<typeof targetsSchema>[number];
