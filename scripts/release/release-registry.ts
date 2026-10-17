// One record per dependency whose releases cloud pins, so a new dependency is one record built
// from the kinds below (docs/runbooks/release-check.md). It imports nothing outside Bun, because
// the release workflows run it without node_modules.

// what a release publishes for its pins beside the version, which decides how the bump reads it
type ReleaseSource =
  | { readonly kind: 'sha256sums' }
  | { readonly kind: 'image-digests'; readonly images: readonly string[] }
  | { readonly kind: 'release-notes' }
  | { readonly kind: 'npm-tarball'; readonly packageName: string }
  | { readonly kind: 'published-images'; readonly images: readonly PublishedImage[] };

// An image this repository's own workflow publishes, at the tag that one line of a pin file names
// in its tag group. The workflow that publishes the images opens their pull request, so the release
// check never reads a published-images record, and the first image's tag is the bump's version.
export interface PublishedImage {
  readonly image: string;
  readonly file: string;
  readonly pattern: string;
}

// A version is read and compared. A tag or a commit moves with the version and is never read. A
// sum, a digest or a tarball sum is the release's own value, which a pin at its version must hold.
// An image tag is the tag a published image carries, which moves with that image's digest.
export type PinPart =
  | { readonly kind: 'version' }
  | { readonly kind: 'tag' }
  | { readonly kind: 'commit'; readonly length: number }
  | { readonly kind: 'sum'; readonly asset: string | PinAssetLine }
  | { readonly kind: 'digest'; readonly image: string }
  | { readonly kind: 'tarball-sum' }
  | { readonly kind: 'image-tag'; readonly image: string };

// the line of a pin file that names the asset whose sum another line pins
export interface PinAssetLine {
  readonly file: string;
  readonly pattern: string;
}

// Exactly one line of the file must match the pattern, a regular expression's source that is
// matched with the u flag; each named group is the part of that name. A source, unlike a RegExp,
// is readonly all the way down.
export interface PinLine {
  readonly file: string;
  readonly pattern: string;
  readonly parts: Readonly<Record<string, PinPart>>;
}

// `nix flake lock` in the flake's directory after the pin's lines are written, which must then
// lock the input at the pinned commit
export interface PinLock {
  readonly kind: 'nix-flake-lock';
  readonly flake: string;
  readonly input: string;
  readonly lockFile: string;
}

export interface Pin {
  readonly id: string;

  // the pin's row in the bump pull request's table, as Markdown
  readonly title: string;
  readonly lines: readonly PinLine[];
  readonly lock?: PinLock;
}

export interface ReleaseRecord {
  readonly name: string;
  readonly repo: string;

  // a release's tag is <tagPrefix>X.Y.Z
  readonly tagPrefix: string;
  readonly source: ReleaseSource;

  // in the order the bump line lists their versions
  readonly pins: readonly Pin[];

  // files that a script in the checkout writes from the release, which a bump runs after its pins
  readonly generated?: GeneratedFiles;

  // the bump pull request's "After the merge:" text, as Markdown
  readonly rollout: string;
}

// the script runs with bun and takes the release's tag as its one argument
interface GeneratedFiles {
  readonly script: string;
  readonly files: readonly string[];
}

const version = { kind: 'version' } as const;

export const releaseRegistry: readonly ReleaseRecord[] = [
  {
    name: 'atc',
    repo: 'zgeoff/atc',
    tagPrefix: '@zgeoff/atc@',
    source: { kind: 'sha256sums' },
    pins: [
      {
        id: 'atc-agent',
        title: 'the agent image (`images/agent/Dockerfile`)',
        lines: [
          {
            file: 'images/agent/Dockerfile',
            pattern: String.raw`^ARG ATC_VERSION=(?<version>\d+\.\d+\.\d+)$`,
            parts: { version },
          },
          {
            file: 'images/agent/Dockerfile',
            pattern: String.raw`^ARG ATC_SHA256=(?<sum>[0-9a-f]{64})$`,
            parts: { sum: { kind: 'sum', asset: 'atc-linux-x64' } },
          },
        ],
      },
      {
        id: 'atc-daemon',
        title: "the host's atc daemon (`nixos/packages/atc.nix`)",
        lines: [
          {
            file: 'nixos/packages/atc.nix',
            pattern: String.raw`^ {2}version = "(?<version>\d+\.\d+\.\d+)";$`,
            parts: { version },
          },
          {
            file: 'nixos/packages/atc.nix',
            pattern: String.raw`^ {2}sha256 = "(?<sum>[0-9a-f]{64})";$`,
            parts: { sum: { kind: 'sum', asset: 'atc-linux-x64' } },
          },
        ],
      },
      {
        id: 'atc-gateway',
        title: 'the atc-gateway images (`images/atc-gateway/versions.env`)',
        lines: [
          {
            file: 'images/atc-gateway/versions.env',
            pattern: String.raw`^ATC_RELEASE=@zgeoff\/atc@(?<version>\d+\.\d+\.\d+)$`,
            parts: { version },
          },
          {
            file: 'images/atc-gateway/versions.env',
            pattern: String.raw`^ATC_ASSET_SHA256=(?<sum>[0-9a-f]{64})$`,
            parts: {
              sum: {
                kind: 'sum',
                asset: {
                  file: 'images/atc-gateway/versions.env',
                  pattern: String.raw`^ATC_ASSET=(?<asset>.+)$`,
                },
              },
            },
          },

          // a published gateway tag is never replaced, so the tag moves with the release
          {
            file: 'images/atc-gateway/versions.env',
            pattern: String.raw`^GATEWAY_IMAGE_TAG=(?<tag>.*)$`,
            parts: { tag: { kind: 'tag' } },
          },
        ],
      },
    ],
    rollout:
      'Rebuild the agent image (`docs/runbooks/agent-image.md`). The atc-gateway images workflow publishes the gateway images and opens the pull request that pins their digests, which the `Deploy prod` workflow applies once it merges (`docs/runbooks/prod-apply.md`). Then switch the host (`docs/runbooks/workflows.md`), which refuses while the deployed gateway runs another atc major than the daemon pin.',
  },
  {
    name: 'atc-gateway-images',
    repo: 'zgeoff/atc',
    tagPrefix: '@zgeoff/atc@',
    source: {
      kind: 'published-images',
      images: [
        {
          image: 'atc-gateway',
          file: 'images/atc-gateway/versions.env',
          pattern: String.raw`^GATEWAY_IMAGE_TAG=(?<tag>\d+\.\d+\.\d+)$`,
        },
        {
          image: 'atc-gateway-backup',
          file: 'images/atc-gateway/versions.env',
          pattern: String.raw`^BACKUP_IMAGE_TAG=(?<tag>[\w.-]+)$`,
        },
      ],
    },
    pins: [
      {
        id: 'atc-gateway-image',
        title: 'the atc-gateway image (`infra/Pulumi.prod.yaml`)',
        lines: [
          {
            file: 'infra/Pulumi.prod.yaml',
            pattern: String.raw`^ +image: ghcr\.io\/zgeoff\/atc-gateway:(?<version>\d+\.\d+\.\d+)@(?<digest>sha256:[0-9a-f]{64})$`,
            parts: { version, digest: { kind: 'digest', image: 'atc-gateway' } },
          },
        ],
      },

      // the backup image's tag has its own revision, so the pin has no release version
      {
        id: 'atc-gateway-backup-image',
        title: 'the atc-gateway backup image (`infra/Pulumi.prod.yaml`)',
        lines: [
          {
            file: 'infra/Pulumi.prod.yaml',
            pattern: String.raw`^ +backupImage: ghcr\.io\/zgeoff\/atc-gateway-backup:(?<tag>[\w.-]+)@(?<digest>sha256:[0-9a-f]{64})$`,
            parts: {
              tag: { kind: 'image-tag', image: 'atc-gateway-backup' },
              digest: { kind: 'digest', image: 'atc-gateway-backup' },
            },
          },
        ],
      },
    ],
    rollout:
      'The `Deploy prod` workflow applies the stack config once CI passes on main, unless its guard holds the plan (`docs/runbooks/prod-apply.md`). For an atc major release, switch the host after the gateway runs it (`docs/runbooks/workflows.md`).',
  },
  {
    name: 'imp',
    repo: 'zgeoff/impz',
    tagPrefix: 'v',
    source: { kind: 'image-digests', images: ['imp-host', 'imp-base'] },
    pins: [
      // imp's NixOS module and the imp-host image move together
      {
        id: 'imp-host',
        title: "imp's NixOS module and the imp-host image (`nixos/`)",
        lines: [
          {
            file: 'nixos/hosts/geoffcloud/configuration.nix',
            pattern: String.raw`^ {4}image = "ghcr\.io\/zgeoff\/imp-host:(?<version>\d+\.\d+\.\d+)@(?<digest>sha256:[0-9a-f]{64})";$`,
            parts: { version, digest: { kind: 'digest', image: 'imp-host' } },
          },
          {
            file: 'nixos/flake.nix',
            pattern: String.raw`^ {6}url = "github:zgeoff\/impz\/(?<commit>[0-9a-f]+)";$`,
            parts: { commit: { kind: 'commit', length: 8 } },
          },
        ],
        lock: {
          kind: 'nix-flake-lock',
          flake: 'nixos',
          input: 'imp',
          lockFile: 'nixos/flake.lock',
        },
      },

      // the agent image builds on imp-base, and the host's preview service boots its imps from it
      {
        id: 'imp-base',
        title: 'the imp-base image (`images/agent/Dockerfile`)',
        lines: [
          {
            file: 'images/agent/Dockerfile',
            pattern: String.raw`^FROM ghcr\.io\/zgeoff\/imp-base:(?<version>\d+\.\d+\.\d+)@(?<digest>sha256:[0-9a-f]{64})$`,
            parts: { version, digest: { kind: 'digest', image: 'imp-base' } },
          },
          {
            file: 'nixos/hosts/geoffcloud/configuration.nix',
            pattern: String.raw`^ {4}impRegistryImage = "ghcr\.io\/zgeoff\/imp-base:(?<version>\d+\.\d+\.\d+)@(?<digest>sha256:[0-9a-f]{64})";$`,
            parts: { version, digest: { kind: 'digest', image: 'imp-base' } },
          },
        ],
      },
    ],
    rollout:
      "Copy impd's database, then switch the host, as `docs/runbooks/workflows.md` (Upgrade imp) describes; rebuild the agent image for imp-base (`docs/runbooks/agent-image.md`).",
  },
  {
    name: 'nixie',
    repo: 'zgeoff/nixie',
    tagPrefix: 'v',
    source: { kind: 'release-notes' },
    pins: [
      {
        id: 'nixie',
        title: 'nixie (`infra/Pulumi.prod.yaml`)',
        lines: [
          {
            file: 'infra/Pulumi.prod.yaml',
            pattern: String.raw`^ +image: ghcr\.io\/zgeoff\/nixie:(?<version>\d+\.\d+\.\d+)@(?<digest>sha256:[0-9a-f]{64})$`,
            parts: { version, digest: { kind: 'digest', image: 'nixie' } },
          },
        ],
      },
      {
        id: 'nixie-web',
        title: 'nixie-web (`infra/Pulumi.prod.yaml`)',
        lines: [
          {
            file: 'infra/Pulumi.prod.yaml',
            pattern: String.raw`^ +webImage: ghcr\.io\/zgeoff\/nixie-web:(?<version>\d+\.\d+\.\d+)@(?<digest>sha256:[0-9a-f]{64})$`,
            parts: { version, digest: { kind: 'digest', image: 'nixie-web' } },
          },
        ],
      },
    ],

    // the contract the scripts' nixie calls type-check against
    generated: {
      script: 'scripts/nixie-api/write-nixie-api-contract.ts',
      files: ['scripts/nixie-api/openapi.d.ts', 'scripts/nixie-api/openapi.json'],
    },
    rollout:
      'The `Deploy prod` workflow applies the stack config once CI passes on main, unless its guard holds the plan (`docs/runbooks/prod-apply.md`). Check the deploy (`docs/runbooks/nixie.md`).',
  },
  {
    name: 'auto-mode',
    repo: 'zgeoff/auto-mode',
    tagPrefix: 'auto-mode-v',
    source: { kind: 'npm-tarball', packageName: 'auto-mode' },
    pins: [
      {
        id: 'auto-mode',
        title: 'the agent image (`images/agent/Dockerfile`)',
        lines: [
          {
            file: 'images/agent/Dockerfile',
            pattern: String.raw`^ARG AUTO_MODE_VERSION=(?<version>\d+\.\d+\.\d+)$`,
            parts: { version },
          },
          {
            file: 'images/agent/Dockerfile',
            pattern: String.raw`^ARG AUTO_MODE_SHA256=(?<sum>[0-9a-f]{64})$`,
            parts: { sum: { kind: 'tarball-sum' } },
          },
        ],
      },
    ],
    rollout:
      'Rebuild the agent image (`docs/runbooks/agent-image.md`). Gateway sessions load the new mod from `/opt/auto-mode/mods/auto-mode` once they start on the new image.',
  },
];
