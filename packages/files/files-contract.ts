import { oc } from '@orpc/contract';
import { z } from 'zod';

// url is https://<host>/<id>/<filename>, and expiresAt is null for an upload that never expires
const uploadSchema = z.object({
  id: z.string(),
  url: z.url(),
  filename: z.string(),
  contentType: z.string(),
  size: z.int().nonnegative(),
  sha256: z.string(),
  createdAt: z.iso.datetime(),
  uploader: z.enum(['agent', 'owner']),
  label: z.string().nullable(),
  link: z.string().nullable(),
  expiresAt: z.iso.datetime().nullable(),
});

// 7d, 30d, never, or an ISO 8601 date or date and time; the service checks the role's limits
const expiresSchema = z.string().min(1).max(64);
const idSchema = z.string().min(1).max(64);

// served under /api, with a bearer token on every call; an upload is a multipart form
export const filesContract = {
  upload: oc
    .route({ method: 'POST', path: '/files', successStatus: 201 })
    .input(
      z.object({
        file: z.file(),
        filename: z.string().optional(),
        label: z.string().max(200).optional(),
        link: z
          .url({ protocol: /^https?$/u })
          .max(2048)
          .optional(),
        expires: expiresSchema.optional(),
      }),
    )
    .output(uploadSchema),
  list: oc
    .route({ method: 'GET', path: '/files' })
    .input(z.object({ includeExpired: z.stringbool().optional() }))
    .output(z.array(uploadSchema)),
  info: oc
    .route({ method: 'GET', path: '/files/{id}' })
    .input(z.object({ id: idSchema }))
    .output(uploadSchema),
  expire: oc
    .route({ method: 'POST', path: '/files/{id}/expire' })
    .input(z.object({ id: idSchema, expires: expiresSchema }))
    .output(uploadSchema),
  remove: oc
    .route({ method: 'DELETE', path: '/files/{id}' })
    .input(z.object({ id: idSchema }))
    .output(z.object({ id: z.string() })),
};

export type UploadOutput = z.infer<typeof uploadSchema>;
