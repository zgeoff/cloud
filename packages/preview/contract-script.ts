import { buildBunPinCheck } from './build-bun-pin-check.ts';
import { bunRelease } from './bun-release.ts';

// The guest script takes the repository and the commit as arguments, never inside its text. Each
// run's imp is new, so the script installs Bun and the dependencies every time.
export const contractScript = `set -eu
mkdir -p /opt/bun/bin /srv/sdk-contract
curl -fsSL -o /opt/bun/bun.tgz ${bunRelease.url}
echo "${bunRelease.sha256}  /opt/bun/bun.tgz" | sha256sum -c - >/dev/null
tar -xzf /opt/bun/bun.tgz -C /opt/bun/bin --strip-components=2 package/bin/bun
export PATH="/opt/bun/bin:$PATH"
cd /srv/sdk-contract
git init -q
git remote add origin "https://github.com/$1.git"
git fetch -q --depth 1 origin "$2"
git checkout -q --force FETCH_HEAD
${buildBunPinCheck(bunRelease.version)}
bun install --frozen-lockfile
NIXIE_SDK_CONTRACT=1 bun test evals/sdk-contract
`;
