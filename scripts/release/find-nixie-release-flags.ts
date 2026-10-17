// The review flags of a nixie bump, from the release notes of the pinned release, the target and
// each release between: `migrations` when a release after the pin adds migrations, and
// `sandbox-images-changed` when the sandbox images differ between the pin and the target.
export interface NixieReleaseNotes {
  readonly pinned: string;
  readonly target: string;
  readonly between: readonly string[];
}

export function findNixieReleaseFlags(notes: NixieReleaseNotes): readonly string[] {
  const migrations = [notes.target, ...notes.between].some((each) => hasMigrations(each));

  const changed =
    collectSandboxImages(notes.pinned).join('\n') !== collectSandboxImages(notes.target).join('\n');

  return [...(migrations ? ['migrations'] : []), ...(changed ? ['sandbox-images-changed'] : [])];
}

// each release lists only its own migrations, so a missing section, a blank one or any text but
// the one sentence nixie writes for a release without one counts as migrations
function hasMigrations(notes: string) {
  const section = findSection(notes, '## Migrations');

  if (section === null) {
    return true;
  }

  const text = section.filter((line) => line.trim() !== '').join('\n');

  return !/^This release adds no migration since v\d+\.\d+\.\d+\.$/u.test(text);
}

// the image references under `## Images`, sorted, except nixie's own two images; until impd adds
// sandbox images itself (GEO-548), a person adds changed ones before the rollout
function collectSandboxImages(notes: string) {
  return (findSection(notes, '## Images') ?? [])
    .filter(
      (line) => line.startsWith('- `') && !/^- `ghcr\.io\/zgeoff\/(?:nixie|nixie-web)@/u.test(line),
    )
    .toSorted();
}

// the lines of the section with the heading, up to the next `## ` heading; null without one
function findSection(notes: string, heading: string) {
  const lines = notes.split('\n');
  const start = lines.indexOf(heading);

  if (start === -1) {
    return null;
  }

  const rest = lines.slice(start + 1);
  const end = rest.findIndex((line) => line.startsWith('## '));

  return end === -1 ? rest : rest.slice(0, end);
}
