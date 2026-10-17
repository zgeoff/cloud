import { plugin } from 'bun';

// openapi-typescript 7 needs the TypeScript 5 compiler API, which TypeScript 7 no longer ships, and
// Bun cannot override one package's peer. So its modules import typescript-5, an alias of
// typescript 5.9.3, and every other module keeps TypeScript 7.
const typescript5 = Bun.fileURLToPath(import.meta.resolve('typescript-5'));

plugin({
  name: 'openapi-typescript on typescript-5',
  setup: (build) => {
    build.onLoad({ filter: /\/openapi-typescript\/dist\/.*\.mjs$/u }, async (module) => {
      const source = await Bun.file(module.path).text();

      return {
        contents: source.replaceAll(
          /from ['"]typescript['"]/gu,
          `from ${JSON.stringify(typescript5)}`,
        ),
        loader: 'js',
      };
    });
  },
});

const openapiTypescript = await import('openapi-typescript');

const header =
  '// Generated from openapi.json beside it by `bun run nixie:openapi <tag>`: never edit it by hand.\n\n';

// The TypeScript types of nixie's contract document, as the committed openapi.d.ts holds them
export async function renderNixieAPITypes(document: string): Promise<string> {
  const nodes = await openapiTypescript.default(document);

  return header + openapiTypescript.astToString(nodes);
}
