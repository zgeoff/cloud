import { appendFile } from 'node:fs/promises';

export interface ExportToolPathsOptions {
  readonly env: Readonly<Record<string, string | undefined>>;
  readonly printErr: (text: string) => void;
}

// pepys's build reads these two variables, so each names the tool it points at
const toolVariables = [
  { variable: 'PEPYS_ZIG_BIN', tool: 'zig' },
  { variable: 'PEPYS_WASM_TOOLS_BIN', tool: 'wasm-tools' },
] as const;

export async function exportToolPaths(options: Readonly<ExportToolPathsOptions>): Promise<number> {
  const githubEnv = options.env['GITHUB_ENV'];

  if (githubEnv === undefined || githubEnv === '') {
    options.printErr('export-tool-paths: GITHUB_ENV is not set\n');

    return 2;
  }

  const found = toolVariables.map((entry) => ({
    variable: entry.variable,
    tool: entry.tool,
    path: Bun.which(entry.tool, { PATH: options.env['PATH'] ?? '' }),
  }));

  const missing = found.filter((entry) => entry.path === null).map((entry) => entry.tool);

  if (missing.length > 0) {
    options.printErr(`export-tool-paths: not on PATH: ${missing.join(', ')}\n`);

    return 1;
  }

  await appendFile(githubEnv, found.map((entry) => `${entry.variable}=${entry.path}\n`).join(''));

  return 0;
}

if (import.meta.main) {
  process.exitCode = await exportToolPaths({
    env: process.env,
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}
