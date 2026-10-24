import { HttpResponse, http } from 'msw';
import type { HttpHandler } from 'msw';

interface StubImpdImage {
  readonly name: string;
  readonly ref: string;
  readonly digest: string;
}

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

interface AddInput {
  readonly name: string;
  readonly ref: string;
}

// impd's images.list and images.add (imp 3.0.2's caller-contract.ts, lines 229 and 234) over oRPC
// 1.15's RPC protocol: POST <url>/rpc/<path> with a {"json", "meta"} body and answer, and an error
// as {"json": {defined, code, status, message}} under the error's status
export function startStubImpdImages(options: Readonly<StubImpdImagesOptions>): StubImpdImages {
  const calls: string[] = [];
  const images: StubImpdImage[] = [...options.images];

  const isAuthorized = (request: Request) =>
    request.headers.get('authorization') === `Bearer ${options.token}`;

  const answerAdd = (input: AddInput) => {
    calls.push(`images.add ${input.name} ${input.ref}`);

    if (options.refusedRefs?.includes(input.ref) === true) {
      return buildRPCError(
        403,
        'FORBIDDEN',
        'token nixie may add only images whose ref starts with ghcr.io/zgeoff/nixie-',
      );
    }

    const image = { name: input.name, ref: input.ref, digest: input.ref.split('@')[1] ?? '' };

    images.push(image);

    return HttpResponse.json({ json: buildImageRecord(image), meta: [[1, 'createdAt']] });
  };

  const handlers = [
    http.post(`${options.url}/rpc/images/list`, (info) => {
      if (!isAuthorized(info.request)) {
        return buildRPCError(401, 'UNAUTHORIZED', 'unauthorized');
      }

      calls.push('images.list');

      return HttpResponse.json({
        json: images.map((image) => buildImageRecord(image)),
        meta: images.map((_, index) => [1, index, 'createdAt']),
      });
    }),
    http.post(`${options.url}/rpc/images/add`, async (info) => {
      if (!isAuthorized(info.request)) {
        return buildRPCError(401, 'UNAUTHORIZED', 'unauthorized');
      }

      const body: unknown = await info.request.json();

      return answerAdd(parseAddInput(body));
    }),
  ];

  return { handlers, calls, images };
}

function buildRPCError(status: number, code: string, message: string) {
  return HttpResponse.json(
    { json: { defined: false, code, status, message }, meta: [] },
    { status },
  );
}

// ImageSchema in imp 3.0.2's packages/api/src/schemas/image-schema.ts; oRPC's serializer marks the
// Date in createdAt with type 1 and its path in meta
function buildImageRecord(image: Readonly<StubImpdImage>) {
  return {
    id: `image-${image.name}`,
    name: image.name,
    ref: image.ref,
    digest: image.digest,
    source: 'oci',
    createdAt: '2026-10-01T00:00:00.000Z',
    sizeBytes: 1_048_576,
    pinned: false,
  };
}

function parseAddInput(body: unknown): AddInput {
  const json = typeof body === 'object' && body !== null && 'json' in body ? body.json : undefined;

  if (
    typeof json !== 'object' ||
    json === null ||
    !('name' in json) ||
    !('ref' in json) ||
    typeof json.name !== 'string' ||
    typeof json.ref !== 'string'
  ) {
    throw new Error(
      `build-stub-impd-images: an add without a name and a ref: ${JSON.stringify(body)}`,
    );
  }

  return { name: json.name, ref: json.ref };
}
