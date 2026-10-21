import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { findJSONField } from '../find-json-field.ts';
import type { ScriptIO } from '../run-or-exit.ts';
import { runOrExit } from '../run-or-exit.ts';
import { runProcess } from '../run-process.ts';
import { withExitCode } from '../with-exit-code.ts';
import { generateNixieAPITypes } from './generate-nixie-api-types.ts';

export interface WriteNixieAPIContractOptions extends ScriptIO {
  readonly args: readonly string[];

  readonly directory: string;
}

const usage = 'usage: write-nixie-api-contract.ts <nixie release tag, such as v0.31.0>\n';

export function writeNixieAPIContract(
  options: Readonly<WriteNixieAPIContractOptions>,
): Promise<number> {
  return withExitCode(options.printErr, async () => {
    const tag = options.args.length === 1 ? options.args[0] : undefined;

    if (tag === undefined || !/^v\d+\.\d+\.\d+$/u.test(tag)) {
      options.printErr(usage);

      return 2;
    }

    // the contents API answers the file base64-encoded
    const answer = await runOrExit(
      options,
      [
        'gh',
        'api',
        `repos/zgeoff/nixie/contents/libs/contract/openapi.json?ref=${tag}`,
        '--jq',
        '.content',
      ],
      {
        env: { ...process.env, GH_TELEMETRY: '0', DO_NOT_TRACK: '1', GH_NO_UPDATE_NOTIFIER: '1' },
        timeoutMs: 60_000,
      },
    );

    const fetched: unknown = JSON.parse(
      Buffer.from(answer.stdout.toString(), 'base64').toString('utf8'),
    );

    const info = findJSONField(fetched, 'info');

    if (typeof info !== 'object' || info === null) {
      options.printErr(`write-nixie-api-contract: nixie ${tag}'s openapi.json has no info\n`);

      return 1;
    }

    // nixie's document carries the version 0 whatever the release, so the vendored copy carries
    // the release's version in its place, which a test compares with the nixie pin
    Reflect.set(info, 'version', tag.replace(/^v/u, ''));

    const document = `${JSON.stringify(fetched, null, 2)}\n`;

    const types = await generateNixieAPITypes(document);

    await writeFile(join(options.directory, 'openapi.json'), document);
    await writeFile(join(options.directory, 'openapi.d.ts'), types);

    options.printOut(`write-nixie-api-contract: wrote nixie ${tag}'s openapi.json and its types\n`);

    return 0;
  });
}

if (import.meta.main) {
  process.exitCode = await writeNixieAPIContract({
    args: process.argv.slice(2),
    directory: import.meta.dir,
    run: runProcess,
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}
