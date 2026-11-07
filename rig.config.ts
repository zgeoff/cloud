import { defineRig } from '@zgeoff/rig';

// Nix checks and shell suites run these lanes, so no TypeScript file takes their suffixes yet;
// the limits bind the first one that does.
export default defineRig({
  lanes: {
    nixos: { limit: '1200s' },
    'alert-rules': { limit: '90s' },
    images: { limit: '15s' },
    fixtures: { limit: '15s' },
  },
});
