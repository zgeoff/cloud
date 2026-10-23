import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { exposure } from '@zgeoff/cloud-topology';
import type { ExposureEntry } from '@zgeoff/cloud-topology';
import { match } from 'ts-pattern';

export interface WriteExposureTableOptions {
  readonly args: readonly string[];
  readonly entries?: readonly ExposureEntry[];
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

const usage = 'usage: write-exposure-table.ts [--check] [repo root]\n';
const page = join('docs', 'reference', 'exposure.md');
const startMarker = '<!-- exposure:start -->';
const endMarker = '<!-- exposure:end -->';

export async function writeExposureTable(
  options: Readonly<WriteExposureTableOptions>,
): Promise<number> {
  const parsed = parseArgs(options.args);

  if (parsed === undefined) {
    options.printErr(usage);

    return 2;
  }

  // an unreadable page reads as empty, which lacks the markers
  const text = await readFile(join(parsed.root, page), 'utf8').catch(() => '');

  const written = renderPage(text, options.entries ?? exposure.entries);

  if (written === undefined) {
    options.printErr(
      `write-exposure-table: cannot read ${page}, or it lacks its ${startMarker} and ${endMarker} markers\n`,
    );

    return 1;
  }

  return written === text
    ? 0
    : applyPage({ path: join(parsed.root, page), written, check: parsed.check }, options);
}

function parseArgs(args: readonly string[]): { check: boolean; root: string } | undefined {
  const check = args[0] === '--check';
  const rest = check ? args.slice(1) : args;

  return rest.length > 1 || rest[0]?.startsWith('-') === true
    ? undefined
    : { check, root: rest[0] ?? '.' };
}

function renderPage(text: string, entries: readonly ExposureEntry[]): string | undefined {
  const start = text.indexOf(startMarker);
  const end = text.indexOf(endMarker);

  return start === -1 || end < start
    ? undefined
    : `${text.slice(0, start + startMarker.length)}\n\n${renderTable(entries)}\n${text.slice(end)}`;
}

const header = ['Name', 'Kind', 'Exposes', 'Scope', 'Reason', 'Auth', 'Ticket'];

function renderTable(entries: readonly ExposureEntry[]): string {
  const rows = [header, ...entries.map((entry) => renderRow(entry))];

  // oxfmt pads each column to its widest cell, so the formatter leaves the written page as it is
  const widths = header.map((_, column) =>
    Math.max(3, ...rows.map((row) => row[column]?.length ?? 0)),
  );

  const renderLine = (cells: readonly string[]) =>
    `| ${cells.map((cell, column) => cell.padEnd(widths[column] ?? 0)).join(' | ')} |\n`;

  return [
    renderLine(header),
    renderLine(widths.map((width) => '-'.repeat(width))),
    ...rows.slice(1).map((row) => renderLine(row)),
  ].join('');
}

function renderRow(entry: ExposureEntry): readonly string[] {
  return [
    `\`${entry.name}\``,
    entry.kind,
    formatExposes(entry),
    entry.scope,
    formatCell(entry.reason),
    entry.kind === 'host-port' ? '' : formatCell(entry.auth ?? ''),
    entry.ticket ?? '',
  ];
}

function formatExposes(entry: ExposureEntry): string {
  return match(entry)
    .with({ kind: 'host-port' }, (hostPort) => {
      const port =
        hostPort.port === undefined ? hostPort.protocol : `${hostPort.protocol} ${hostPort.port}`;

      return hostPort.interface === undefined ? port : `${port} on \`${hostPort.interface}\``;
    })
    .with({ kind: 'tunnel-hostname' }, (route) => `\`${route.hostname}\``)
    .with(
      { kind: 'front-route' },
      (route) =>
        `\`${route.hostname}\` to \`${route.upstream}\`: ${route.paths.map((path) => `\`${path}\``).join(', ')}`,
    )
    .with({ kind: 'tailnet-capability' }, (capability) => `node attribute \`${capability.attr}\``)
    .with({ kind: 'worker-url' }, (worker) => `\`${worker.script}\` on workers.dev`)
    .exhaustive();
}

function formatCell(text: string): string {
  // a pipe would end the cell
  return text.replaceAll('|', String.raw`\|`);
}

interface PageChange {
  readonly path: string;
  readonly written: string;
  readonly check: boolean;
}

async function applyPage(
  change: PageChange,
  options: Readonly<WriteExposureTableOptions>,
): Promise<number> {
  if (change.check) {
    options.printErr(
      `write-exposure-table: ${page} differs from packages/topology/exposure.json; run bun run docs:exposure\n`,
    );

    return 1;
  }

  await writeFile(change.path, change.written);

  options.printOut(`write-exposure-table: wrote ${page}\n`);

  return 0;
}

if (import.meta.main) {
  process.exitCode = await writeExposureTable({
    args: process.argv.slice(2),
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}
