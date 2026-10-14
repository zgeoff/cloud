import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { exposure } from '@zgeoff/cloud-topology';
import type { ExposureEntry } from '@zgeoff/cloud-topology';

// Writes the exposure registry into docs/reference/exposure.md as a table, between the page's
// markers. With --check it writes nothing: 0 when the page matches the registry or was written, 1
// on a difference or an unreadable page.
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

// [--check] [repo root], or undefined for any other arguments
function parseArgs(args: readonly string[]): { check: boolean; root: string } | undefined {
  const check = args[0] === '--check';
  const rest = check ? args.slice(1) : args;

  return rest.length > 1 || rest[0]?.startsWith('-') === true
    ? undefined
    : { check, root: rest[0] ?? '.' };
}

// a page that differs from the registry: its path, its text with the table, and the mode
interface PageChange {
  readonly path: string;
  readonly written: string;
  readonly check: boolean;
}

// the page with the table between its markers, or undefined when it lacks them
function renderPage(text: string, entries: readonly ExposureEntry[]): string | undefined {
  const start = text.indexOf(startMarker);
  const end = text.indexOf(endMarker);

  return start === -1 || end < start
    ? undefined
    : `${text.slice(0, start + startMarker.length)}\n\n${renderTable(entries)}\n${text.slice(end)}`;
}

// writes the page that differs from the registry, or fails the check without writing it
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

const header = ['Name', 'Kind', 'Exposes', 'Scope', 'Reason', 'Ticket'];

// A table with each column padded to its widest cell, as oxfmt lays a Markdown table out, so the
// formatter leaves the written page as it is
function renderTable(entries: readonly ExposureEntry[]): string {
  const rows = [header, ...entries.map((entry) => renderRow(entry))];

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
    entry.reason.replaceAll('|', String.raw`\|`),
    entry.ticket ?? '',
  ];
}

function formatExposes(entry: ExposureEntry): string {
  switch (entry.kind) {
    case 'host-port': {
      const port = entry.port === undefined ? entry.protocol : `${entry.protocol} ${entry.port}`;

      return entry.interface === undefined ? port : `${port} on \`${entry.interface}\``;
    }
    case 'tunnel-hostname': {
      return `\`${entry.hostname}\``;
    }
    case 'tailnet-capability': {
      return `node attribute \`${entry.attr}\``;
    }
    default: {
      return `\`${entry.script}\` on workers.dev`;
    }
  }
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
