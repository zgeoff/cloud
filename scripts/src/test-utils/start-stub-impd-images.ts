import { ORPCError } from '@impz/client';
import type { Image, ImpClient } from '@impz/client';
import { StandardRPCJsonSerializer, StandardRPCSerializer } from '@orpc/client/standard';
import { HttpResponse, http } from 'msw';
import type { HttpHandler } from 'msw';
import { z } from 'zod';

type StubImpdImage = Pick<Image, 'name' | 'ref' | 'digest'>;

export interface StubImpdImagesOptions {
  readonly url: string;
  readonly token: string;
  readonly images: readonly StubImpdImage[];

  // an add of one of these refs gets impd's refusal of a ref outside the token's prefix
  readonly refusedRefs?: readonly string[];
}

export interface StubImpdImages {
  readonly handlers: readonly HttpHandler[];

  // each procedure called, in order, as `images.list` or `images.add <name> <ref>`
  readonly calls: readonly string[];
  readonly images: readonly StubImpdImage[];
}

const serializer = new StandardRPCSerializer(new StandardRPCJsonSerializer());

// impd also adds an image from an imp; the stub takes only an OCI ref, with the name its caller
// gives, and refuses any other body
const addInputSchema = z.object({
  name: z.string(),
  ref: z.string(),
}) satisfies z.ZodType<Parameters<ImpClient['images']['add']>[0]>;

type AddInput = z.infer<typeof addInputSchema>;

// @impz/client does not export imp's contract, so the routes follow imp 3.0.2's
// caller-contract.ts (images.list at line 229, images.add at line 234) under oRPC's RPC path
// rule, POST <url>/rpc/<path>; oRPC's own serializer encodes each body as an RPC handler does
export function startStubImpdImages(options: Readonly<StubImpdImagesOptions>): StubImpdImages {
  const calls: string[] = [];
  const images: StubImpdImage[] = [...options.images];

  const isAuthorized = (request: Request) =>
    request.headers.get('authorization') === `Bearer ${options.token}`;

  const answerAdd = (input: AddInput) => {
    calls.push(`images.add ${input.name} ${input.ref}`);

    if (options.refusedRefs?.includes(input.ref) === true) {
      return buildRPCError(
        new ORPCError('FORBIDDEN', {
          message: 'token nixie may add only images whose ref starts with ghcr.io/zgeoff/nixie-',
        }),
      );
    }

    const image = { name: input.name, ref: input.ref, digest: input.ref.split('@')[1] ?? '' };

    images.push(image);

    return buildRPCAnswer(buildImageRecord(image));
  };

  const handlers = [
    http.post(`${options.url}/rpc/images/list`, (info) => {
      if (!isAuthorized(info.request)) {
        return buildRPCError(new ORPCError('UNAUTHORIZED', { message: 'unauthorized' }));
      }

      calls.push('images.list');

      return buildRPCAnswer(images.map((image) => buildImageRecord(image)));
    }),
    http.post(`${options.url}/rpc/images/add`, async (info) => {
      if (!isAuthorized(info.request)) {
        return buildRPCError(new ORPCError('UNAUTHORIZED', { message: 'unauthorized' }));
      }

      const body: unknown = await info.request.json();

      return answerAdd(addInputSchema.parse(serializer.deserialize(body)));
    }),
  ];

  return { handlers, calls, images };
}

function buildRPCError(error: ORPCError<string, unknown>) {
  return HttpResponse.json(serializer.serialize(error.toJSON()), { status: error.status });
}

function buildRPCAnswer(output: unknown) {
  return HttpResponse.json(serializer.serialize(output));
}

function buildImageRecord(image: Readonly<StubImpdImage>): Image {
  return {
    id: `image-${image.name}`,
    name: image.name,
    ref: image.ref,
    digest: image.digest,
    source: 'oci',
    createdAt: new Date('2026-10-01T00:00:00.000Z'),
    sizeBytes: 1_048_576,
    pinned: false,
  };
}
