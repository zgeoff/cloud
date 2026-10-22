export interface NixieReleaseNotes {
  readonly pinned: string;
  readonly target: string;
  readonly between: readonly string[];
}

export function collectNixieReleaseFlags(notes: NixieReleaseNotes): readonly string[] {
  const migrations = [notes.target, ...notes.between].some((each) => hasMigrations(each));

  // nixie's token cannot pin, so delivery pins a release's new sandbox images after the rollout
  const changed =
    collectSandboxImages(notes.pinned).join('\n') !== collectSandboxImages(notes.target).join('\n');

  return [...(migrations ? ['migrations'] : []), ...(changed ? ['sandbox-images-changed'] : [])];
}

function hasMigrations(notes: string) {
  const section = findSection(notes, '## Migrations');

  // each release lists only its own migrations, so a release whose notes lack the section counts
  if (section === null) {
    return true;
  }

  // nixie puts a whole-line HTML comment above the next heading, which is not text
  const text = section
    .filter((line) => line.trim() !== '' && !/^\s*<!--.*-->\s*$/u.test(line))
    .join('\n');

  return !/^This release adds no migration since v\d+\.\d+\.\d+\.$/u.test(text);
}

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

function collectSandboxImages(notes: string) {
  return (findSection(notes, '## Images') ?? [])
    .filter(
      (line) => line.startsWith('- `') && !/^- `ghcr\.io\/zgeoff\/(?:nixie|nixie-web)@/u.test(line),
    )
    .toSorted();
}
