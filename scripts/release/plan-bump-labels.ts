import { isNewerVersion } from './is-newer-version.ts';
import { parseReleaseVersion } from './parse-release-version.ts';

// The labels of a bump pull request, in order: its update type, the largest step from a pin older
// than the version (a pin at the version or newer moves nothing); each review flag; and
// needs-review or auto-merge, by the rules in docs/runbooks/release-check.md.
export function planBumpLabels(
  version: string,
  pinned: readonly string[],
  flags: readonly string[],
): readonly string[] | Error {
  const target = parseReleaseVersion(version);
  const invalid = [version, ...pinned].find((each) => parseReleaseVersion(each) === undefined);

  if (target === undefined || invalid !== undefined) {
    return new Error(`not a release version: '${invalid ?? version}'`);
  }

  const steps = new Set(
    pinned
      .map((each) => parseReleaseVersion(each) ?? target)
      .filter((each) => isNewerVersion(target, each))
      .map((each) => pickStep(each.major !== target.major, each.minor !== target.minor)),
  );

  const update = (['major', 'minor', 'patch'] as const).find((step) => steps.has(step));

  if (update === undefined) {
    return new Error(`no pinned version is older than ${version}`);
  }

  // from 1.0 on, patch and minor updates merge on their own; a 0.x minor release is the breaking one
  const review =
    update === 'major' || (update === 'minor' && target.major === 0) || flags.length > 0;

  return [`update:${update}`, ...flags, review ? 'needs-review' : 'auto-merge'];
}

function pickStep(majorDiffers: boolean, minorDiffers: boolean) {
  if (majorDiffers) {
    return 'major';
  }

  return minorDiffers ? 'minor' : 'patch';
}
