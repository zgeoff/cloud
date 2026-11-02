const version = '1.4.4';

// Bun's linux-x64 build from its npm package, because imp's base image has tar but no unzip for the
// release zip. The sha256 is the tarball's own, which matches npm's published integrity.
export const bunRelease = {
  version,
  url: `https://registry.npmjs.org/@oven/bun-linux-x64/-/bun-linux-x64-${version}.tgz`,
  sha256: '93ca5a2abe45f3bcac6dd55baff8bb06c4ac824b70f89650b54e5c8b80dbef18',
} as const;
