import type { z } from 'zod';

export function parseStackObject<Schema extends z.ZodType>(
  key: string,
  raw: unknown,
  schema: Schema,
): z.output<Schema> {
  const result = schema.safeParse(raw);

  if (!result.success) {
    throw new Error(result.error.issues.map((issue) => formatIssue(key, issue)).join('\n'));
  }

  return result.data;
}

function formatIssue(key: string, issue: z.core.$ZodIssue): string {
  return `stack config "${[key, ...issue.path.map(String)].join('.')}" ${issue.message}`;
}
