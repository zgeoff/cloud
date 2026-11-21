import { defineRig } from '@zgeoff/rig';

// Nix checks and shell suites run these lanes, and the lint rules hold a TypeScript test with a
// lane's suffix to that lane's limit.
export default defineRig({
  // bunfig.toml's pathIgnorePatterns, less scripts/e2e, which rig's e2e lane runs
  ignore: ['workers/**', 'packages/preview/**', 'packages/files/**'],

  // the e2e journeys run without the root preload's test network and faker seed
  bunfigs: [{ path: 'scripts/e2e/bunfig.toml', files: ['scripts/e2e/**'] }],
  programs: {
    'build-agent-image': {
      package: 'scripts',
      source: 'build-agent-image.ts',
      build: 'bun build build-agent-image.ts --target=bun --outfile dist/build-agent-image.js',
      artifact: 'dist/build-agent-image.js',
    },
  },
  lanes: {
    nixos: { limit: '1200s' },
    'alert-rules': { limit: '90s' },
    images: { limit: '15s' },
    fixtures: { limit: '15s' },
  },
});
