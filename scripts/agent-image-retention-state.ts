import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { findJSONField } from './find-json-field.ts';

export interface AgentImageRetentionState {
  // every atc config file that switch-agent-image changed
  readonly configs: readonly string[];

  // images that switch-agent-image pinned although no passing check had pinned them
  readonly switchOnlyImages: readonly string[];
}

export interface AgentImageRetentionChange {
  readonly config?: string;
  readonly switchOnlyImage?: string;
  readonly passedImage?: string;
}

function getRetentionStateFile(home: string): string {
  return join(home, '.local/state/cloud/agent-image-retention.json');
}

// Reads what the switch and build scripts on this machine left for each other. A missing file
// holds nothing, and a file that cannot be read or parsed throws, so the caller keeps every image
// rather than guess.
export async function readAgentImageRetentionState(
  home: string,
): Promise<AgentImageRetentionState> {
  let text: string;

  try {
    text = await readFile(getRetentionStateFile(home), 'utf8');
  } catch (error) {
    if (error instanceof Error && 'code' in error && error.code === 'ENOENT') {
      return { configs: [], switchOnlyImages: [] };
    }

    throw error;
  }

  const parsed: unknown = JSON.parse(text);

  return {
    configs: toStrings(findJSONField(parsed, 'configs')),
    switchOnlyImages: toStrings(findJSONField(parsed, 'switchOnlyImages')),
  };
}

// A switch records its config file, so a later build reads that target wherever the file lives,
// and the image it pinned for want of a passing check. A passing build clears its image from the
// switch-only list.
export async function recordAgentImageRetention(
  home: string,
  change: Readonly<AgentImageRetentionChange>,
): Promise<void> {
  const state = await readAgentImageRetentionState(home);

  const configs = new Set(state.configs);
  const switchOnly = new Set(state.switchOnlyImages);

  if (change.config !== undefined) {
    configs.add(change.config);
  }

  if (change.switchOnlyImage !== undefined) {
    switchOnly.add(change.switchOnlyImage);
  }

  if (change.passedImage !== undefined) {
    switchOnly.delete(change.passedImage);
  }

  const file = getRetentionStateFile(home);

  await mkdir(dirname(file), { recursive: true });

  const next = JSON.stringify({ configs: [...configs], switchOnlyImages: [...switchOnly] });

  // other sessions can write the file, so it is replaced in one rename
  await writeFile(`${file}.tmp-${process.pid}`, `${next}\n`);
  await rename(`${file}.tmp-${process.pid}`, file);
}

function toStrings(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((item): item is string => typeof item === 'string')
    : [];
}
