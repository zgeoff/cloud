import { isDeepStrictEqual } from 'node:util';
import { buildPepysRouteTable } from './build-pepys-route-table.ts';

export interface CheckPepysRoutesOptions {
  readonly args: readonly string[];

  // the deployment as JSON, which keeps every field the table needs and drops the functions
  readonly deploymentText: string;
  readonly printErr: (text: string) => void;
}

const usage = 'usage: <deployment as JSON> | check-pepys-routes.ts <route table file>\n';

// Compares deploy/pepys/ingest-routes.json with the routes and variables of the deployment that
// the image holds, so the cluster opens and fills exactly what ingest serves and reads.
export async function checkPepysRoutes(
  options: Readonly<CheckPepysRoutesOptions>,
): Promise<number> {
  const [tableFile] = options.args;

  if (options.args.length !== 1 || tableFile === undefined) {
    options.printErr(usage);

    return 2;
  }

  const deployment: unknown = JSON.parse(options.deploymentText);
  const expected = buildPepysRouteTable(deployment);

  const committed: unknown = await Bun.file(tableFile).json();

  if (isDeepStrictEqual(committed, expected)) {
    return 0;
  }

  options.printErr(
    `check-pepys-routes: ${tableFile} differs from the deployment; it must hold:\n${JSON.stringify(expected, null, 2)}\n`,
  );

  return 1;
}

if (import.meta.main) {
  process.exitCode = await checkPepysRoutes({
    args: process.argv.slice(2),
    deploymentText: await Bun.stdin.text(),
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}
