import { z } from 'zod';

// infra builds this payload for the Command that runs before nixie rolls, and the deploy's script
// parses it there
export const nixieSandboxImagesPayloadSchema = z.strictObject({
  namespace: z.string(),
  configMap: z.string(),
  scriptKey: z.string(),

  // the Job's manifest as JSON, which kubectl creates as it is
  job: z.string(),
});

export type NixieSandboxImagesPayload = z.infer<typeof nixieSandboxImagesPayloadSchema>;
