import { join } from 'node:path';
import type { BunPlugin } from 'bun';

// Compiles ingest.ts and api.ts into the image's pepys-ingest and pepys-api, each one linux-x64
// binary that needs no Bun or node_modules beside it.
//
//   bun compile-entries.ts <dir>
//
// Turso's loader requires its native addon through createRequire, which `bun build --compile`
// does not follow, so the compiled API stops at start without the addon. This plugin drops that
// createRequire, so the bundler sees the loader's require calls and embeds the addon. It fails the
// build when the loader no longer holds that line, so a Turso release that changes it never yields
// an API that cannot start.
const tursoLoader = /[\\/]@tursodatabase[\\/]database[\\/]index\.js$/u;
const createRequireLine = 'const require = createRequire(import.meta.url)';

const tursoStaticRequire: BunPlugin = {
  name: 'turso-static-require',
  setup(build) {
    build.onLoad({ filter: tursoLoader }, async (args) => {
      const text = await Bun.file(args.path).text();

      if (!text.includes(createRequireLine)) {
        throw new Error(`${args.path} no longer holds "${createRequireLine}"`);
      }

      return { contents: text.replace(createRequireLine, ''), loader: 'js' };
    });
  },
};

const outDir = process.argv[2];

if (process.argv.length !== 3 || outDir === undefined) {
  console.error('usage: bun compile-entries.ts <dir>');
  process.exit(2);
}

for (const [entry, binary] of [
  ['ingest.ts', 'pepys-ingest'],
  ['api.ts', 'pepys-api'],
] as const) {
  const result = await Bun.build({
    entrypoints: [join(import.meta.dir, entry)],
    compile: { target: 'bun-linux-x64', outfile: join(outDir, binary) },
    minify: true,
    plugins: [tursoStaticRequire],
  });

  if (!result.success) {
    console.error(result.logs.map(String).join('\n'));
    process.exit(1);
  }
}
