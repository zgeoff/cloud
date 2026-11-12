import { z } from 'zod';

const manifestSchema = z.looseObject({
  dependencies: z.record(z.string(), z.string()).optional(),
});

// The image's host comes from PEPYS_RELEASE in images/pepys/versions.env, and its other programs from
// the @pepys/* packages in deploy/pepys/package.json. Nothing bumps both, so a release bump changes
// them by hand in one pull request; this names each pin left behind, or the one it cannot read.
export function collectPepysVersionMismatches(
  versionsEnv: string,
  deploymentManifest: unknown,
): string[] {
  const release = /^PEPYS_RELEASE=v(?<version>\d+\.\d+\.\d+)$/mu.exec(versionsEnv)?.groups?.[
    'version'
  ];

  if (release === undefined) {
    return ['images/pepys/versions.env has no PEPYS_RELEASE=v<major>.<minor>.<patch> line'];
  }

  const packages = Object.entries(
    manifestSchema.parse(deploymentManifest).dependencies ?? {},
  ).filter(([name]) => name.startsWith('@pepys/'));

  if (packages.length === 0) {
    return ['deploy/pepys/package.json depends on no @pepys/* package'];
  }

  return packages
    .filter(([, version]) => version !== release)
    .map(
      ([name, version]) =>
        `deploy/pepys/package.json pins ${name} at ${version}, but images/pepys/versions.env pins the release v${release}`,
    );
}
