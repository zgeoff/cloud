import { z } from 'zod';

const nixieConfigSchema = z.object({ image: z.string() });

const stackConfigSchema = z.object({
  config: z.object({ 'geoff-cloud:nixie': nixieConfigSchema }),
});

const imagePattern = /^ghcr\.io\/zgeoff\/nixie:(?<version>\d+\.\d+\.\d+)@sha256:[0-9a-f]{64}$/u;

// The release of the nixie image that the stack config pins, such as 0.74.0.
export function findNixieVersion(stackConfigText: string): string | null {
  const parsed = stackConfigSchema.safeParse(Bun.YAML.parse(stackConfigText));

  if (!parsed.success) {
    return null;
  }

  return (
    imagePattern.exec(parsed.data.config['geoff-cloud:nixie'].image)?.groups?.['version'] ?? null
  );
}
