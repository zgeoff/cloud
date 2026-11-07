import { defineRig } from '@zgeoff/rig';

// Nix checks and shell suites run these lanes, and the lint rules hold a TypeScript test with a
// lane's suffix to that lane's limit.
export default defineRig({
  // the same folders as bunfig.toml's pathIgnorePatterns
  ignore: ['workers/**', 'packages/preview/**', 'packages/files/**', 'e2e/**'],
  lanes: {
    nixos: { limit: '1200s' },
    'alert-rules': { limit: '90s' },
    images: { limit: '15s' },
    fixtures: { limit: '15s' },
  },
});
