import { findAssetSum } from './find-asset-sum.ts';
import type { PinMatch } from './find-pin-match.ts';
import { findPinMatch } from './find-pin-match.ts';
import { isNewerVersion } from './is-newer-version.ts';
import { parseReleaseVersion } from './parse-release-version.ts';
import type { Pin, PinPart, ReleaseRecord } from './release-registry.ts';

// what the release publishes for its pins, as its source kind reads it
export interface ReleaseValues {
  readonly sha256sums?: string;
  readonly digests?: Readonly<Record<string, string>>;
  readonly commit?: string;
  readonly tarballSum?: string;

  // the tag of each image this repository publishes, by image
  readonly tags?: Readonly<Record<string, string>>;
}

export interface PinEditsInput {
  readonly record: ReleaseRecord;
  readonly version: string;
  readonly values: ReleaseValues;

  // the contents of every file the record's pins read, by path from the repo root
  readonly files: Readonly<Record<string, string>>;
}

export interface PinPlan {
  // the new contents of each file that a pin changes
  readonly files: Readonly<Record<string, string>>;

  // what happens to each pin, one line each, in the record's order
  readonly notes: readonly string[];

  // the pins it moves, whose lock runs after the write
  readonly written: readonly Pin[];
}

// Plans the pins of a release: a pin older than the version moves to it with the release's
// values, a pin at the version must already hold them, and a newer pin stays. Every check runs
// before any file changes, so an Error leaves every file as it was.
export function planPinEdits(input: PinEditsInput): PinPlan | Error {
  if (parseReleaseVersion(input.version) === undefined) {
    return new Error(`not a release version: '${input.version}'`);
  }

  const steps: PinStep[] = [];

  for (const pin of input.record.pins) {
    const step = planPin(pin, input);

    if (step instanceof Error) {
      return step;
    }

    steps.push(step);
  }

  return {
    files: mergeLineEdits(
      input.files,
      steps.flatMap((step) => step.edits),
    ),
    notes: steps.map((step) => step.note),
    written: steps.filter((step) => step.edits.length > 0).map((step) => step.pin),
  };
}

interface LineEdit {
  readonly file: string;
  readonly index: number;
  readonly text: string;
}

interface PinStep {
  readonly pin: Pin;
  readonly note: string;
  readonly edits: readonly LineEdit[];
}

function planPin(pin: Pin, input: PinEditsInput): PinStep | Error {
  const matches = collectMatches(pin, input.files);
  const wanted = collectWantedParts(pin, input);

  if (matches instanceof Error) {
    return matches;
  }

  if (wanted instanceof Error) {
    return wanted;
  }

  const held = collectHeldParts(pin, matches);

  if (held instanceof Error) {
    return held;
  }

  return planPinStep({ pin, matches, wanted, held, version: input.version });
}

interface PinState {
  readonly pin: Pin;
  readonly matches: readonly PinMatch[];
  readonly wanted: Readonly<Record<string, string>>;
  readonly held: Readonly<Record<string, string>>;
  readonly version: string;
}

function planPinStep(state: PinState): PinStep | Error {
  if (state.held['version'] === undefined) {
    return planTagStep(state);
  }

  const pinned = state.held['version'];

  if (pinned === state.version) {
    return (
      findOtherValue(state) ?? {
        pin: state.pin,
        note: `${state.pin.id} already pins ${state.version}`,
        edits: [],
      }
    );
  }

  // a release job that finishes after a newer release's job must not move the pin back
  if (isPinnedNewer(pinned, state.version)) {
    return {
      pin: state.pin,
      note: `${state.pin.id} pins ${pinned}, which is newer than ${state.version}`,
      edits: [],
    };
  }

  return {
    pin: state.pin,
    note: `pinned ${state.pin.id} ${state.version}`,
    edits: planLineEdits(state),
  };
}

// A pin with no version, such as an image tag with its own revision, has no order to keep: it
// moves to the release's values whenever they differ from the ones it holds.
function planTagStep(state: PinState): PinStep {
  const keys = Object.keys(state.wanted);
  const to = keys.map((key) => state.wanted[key] ?? '').join(' ');

  return keys.every((key) => state.held[key] === state.wanted[key])
    ? { pin: state.pin, note: `${state.pin.id} already pins ${to}`, edits: [] }
    : { pin: state.pin, note: `pinned ${state.pin.id} ${to}`, edits: planLineEdits(state) };
}

function collectMatches(pin: Pin, files: Readonly<Record<string, string>>) {
  const matches: PinMatch[] = [];

  for (const line of pin.lines) {
    const match = findPinMatch(files, line);

    if (match instanceof Error) {
      return match;
    }

    matches.push(match);
  }

  return matches;
}

// each part's value at the release, keyed as the part's identity
function collectWantedParts(pin: Pin, input: PinEditsInput) {
  const wanted: Record<string, string> = {};

  for (const part of pin.lines.flatMap((line) => Object.values(line.parts))) {
    const value = resolvePart(part, input);

    if (value instanceof Error) {
      return value;
    }

    wanted[toPartKey(part)] = value;
  }

  return wanted;
}

type PartResolver<Part extends PinPart> = (part: Part, input: PinEditsInput) => string | Error;

// One resolver per part kind. The release workflows run these scripts without node_modules, so a
// keyed record branches here in place of ts-pattern's match, and its type still needs every kind.
const partResolvers: {
  readonly [Kind in PinPart['kind']]: PartResolver<Extract<PinPart, { kind: Kind }>>;
} = {
  version: (_, input) => input.version,
  tag: (_, input) => input.version,
  commit: (part, input) =>
    input.values.commit?.slice(0, part.length) ?? new Error('the release names no commit'),
  sum: (part, input) => resolveSum(part.asset, input),
  digest: (part, input) =>
    input.values.digests?.[part.image] ?? new Error(`the release lists no ${part.image} digest`),
  'tarball-sum': (_, input) =>
    input.values.tarballSum ?? new Error('the release has no tarball sum'),
  'image-tag': (part, input) =>
    input.values.tags?.[part.image] ?? new Error(`the release names no ${part.image} tag`),
};

function resolvePart(part: PinPart, input: PinEditsInput): string | Error {
  const resolver = partResolvers[part.kind] as PartResolver<typeof part> | undefined;

  // the type check refuses a kind with no resolver, so only a registry built outside it lands here
  return resolver === undefined
    ? new Error('the registry names a pin part kind that no resolver reads')
    : resolver(part, input);
}

function resolveSum(asset: Extract<PinPart, { kind: 'sum' }>['asset'], input: PinEditsInput) {
  if (typeof asset === 'string') {
    return findAssetSum(input.values.sha256sums ?? '', asset);
  }

  const named = findPinMatch(input.files, asset);

  return named instanceof Error
    ? named
    : findAssetSum(input.values.sha256sums ?? '', named.groups['asset'] ?? '');
}

// the values the pin holds, keyed as the part's identity: every line that holds the version, a
// sum or a digest must agree with the others
function collectHeldParts(pin: Pin, matches: readonly PinMatch[]) {
  const held: Record<string, string> = {};

  for (const [index, line] of pin.lines.entries()) {
    for (const [group, part] of Object.entries(line.parts)) {
      const value = matches[index]?.groups[group] ?? '';
      const known = held[toPartKey(part)];

      if (known !== undefined && known !== value && part.kind !== 'tag' && part.kind !== 'commit') {
        return new Error(
          `${pin.id} pins ${known} in one line and ${value} in another: pin both at one release`,
        );
      }

      held[toPartKey(part)] = known ?? value;
    }
  }

  return held;
}

// a pin at the release's version must already hold the release's values
function findOtherValue(state: PinState) {
  const key = state.pin.lines
    .flatMap((line) => Object.values(line.parts))
    .filter((part) => part.kind === 'sum' || part.kind === 'digest' || part.kind === 'tarball-sum')
    .map((part) => toPartKey(part))
    .find((each) => state.held[each] !== state.wanted[each]);

  return key === undefined
    ? undefined
    : new Error(
        `${state.pin.id} pins ${state.version} with ${state.held[key] ?? ''}, but the release lists ${state.wanted[key] ?? ''}`,
      );
}

type Span = PinMatch['spans'][string];

function planLineEdits(state: PinState): LineEdit[] {
  return state.pin.lines.flatMap((line, index) => {
    const match = state.matches[index];

    if (match === undefined) {
      return [];
    }

    // replace the groups from the last to the first, so each span stays where it was
    const spans = Object.entries(match.spans).toSorted(
      (left: readonly [string, Span], right: readonly [string, Span]) => right[1][0] - left[1][0],
    );

    let text = match.text;

    for (const [group, [start, end]] of spans) {
      const part = line.parts[group];
      const value = part === undefined ? undefined : state.wanted[toPartKey(part)];

      text = value === undefined ? text : `${text.slice(0, start)}${value}${text.slice(end)}`;
    }

    return [{ file: line.file, index: match.index, text }];
  });
}

function mergeLineEdits(files: Readonly<Record<string, string>>, edits: readonly LineEdit[]) {
  const lines: Record<string, string[]> = {};

  for (const edit of edits) {
    const fileLines = lines[edit.file] ?? (files[edit.file] ?? '').split('\n');

    fileLines[edit.index] = edit.text;
    lines[edit.file] = fileLines;
  }

  return Object.fromEntries(
    Object.keys(lines).map((file) => [file, lines[file]?.join('\n') ?? '']),
  );
}

function isPinnedNewer(pinned: string, version: string) {
  const held = parseReleaseVersion(pinned);
  const target = parseReleaseVersion(version);

  return held !== undefined && target !== undefined && isNewerVersion(held, target);
}

// parts of one kind and image hold one value across a pin's lines
function toPartKey(part: PinPart) {
  return part.kind === 'digest' || part.kind === 'image-tag'
    ? `${part.kind}:${part.image}`
    : part.kind;
}
