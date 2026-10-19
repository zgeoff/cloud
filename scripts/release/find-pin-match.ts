import type { PinAssetLine, PinLine } from './release-registry.ts';

export interface PinMatch {
  readonly index: number;
  readonly text: string;
  readonly groups: Readonly<Record<string, string>>;
  readonly spans: Readonly<Record<string, readonly [number, number]>>;
}

export function findPinMatch(
  files: Readonly<Record<string, string>>,
  line: PinLine | PinAssetLine,
): PinMatch | Error {
  const contents = files[line.file];

  if (contents === undefined) {
    return new Error(`${line.file} is missing: run this from the root of a zgeoff/cloud checkout`);
  }

  const pattern = new RegExp(line.pattern, 'du');

  const matches = contents.split('\n').flatMap((text, index) => {
    const match = pattern.exec(text);

    return match === null ? [] : [{ index, text, match }];
  });

  const [found, ...others] = matches;

  if (found === undefined || others.length > 0) {
    return new Error(
      `${line.file} has ${matches.length} lines that match '${line.pattern}', want 1`,
    );
  }

  return {
    index: found.index,
    text: found.text,
    groups: { ...found.match.groups },
    spans: { ...found.match.indices?.groups },
  };
}
