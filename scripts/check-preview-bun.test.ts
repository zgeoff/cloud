import { expect, test } from 'bun:test';
import { buildBunPinCheck } from '@zgeoff/cloud-preview/build-bun-pin-check.ts';
import { HttpResponse, http } from 'msw';
import { checkPreviewBun } from './check-preview-bun.ts';
import { server } from './mocks/node.ts';

test('it passes a script that downloads, checks and pins the release before the install, whose tarball matches its sha256', async () => {
  server.use(
    http.get(
      'https://registry.npmjs.org/@oven/bun-linux-x64/-/bun-linux-x64-7.3.1.tgz',
      () => new HttpResponse('stand-in bun tarball'),
    ),
  );

  const printed: string[] = [];

  const exitCode = await checkPreviewBun({
    release: {
      version: '7.3.1',
      url: 'https://registry.npmjs.org/@oven/bun-linux-x64/-/bun-linux-x64-7.3.1.tgz',
      sha256: '20d515c5354423ecfc74411c4ea4d55aa29d35dce93641fe1e6c93acd9b5e63e',
    },
    script: `set -eu
curl -fsSL -o /opt/bun/bun.tgz https://registry.npmjs.org/@oven/bun-linux-x64/-/bun-linux-x64-7.3.1.tgz
echo "20d515c5354423ecfc74411c4ea4d55aa29d35dce93641fe1e6c93acd9b5e63e  /opt/bun/bun.tgz" | sha256sum -c - >/dev/null
${buildBunPinCheck('7.3.1')}
bun install --frozen-lockfile
`,
    printErr: (text) => {
      printed.push(text);
    },
  });

  expect({ exitCode, printed }).toStrictEqual({ exitCode: 0, printed: [] });
});

test('it fails a release whose tarball has another sha256 than the pin', async () => {
  server.use(
    http.get(
      'https://registry.npmjs.org/@oven/bun-linux-x64/-/bun-linux-x64-7.3.1.tgz',
      () => new HttpResponse('another bun tarball'),
    ),
  );

  const printed: string[] = [];

  const exitCode = await checkPreviewBun({
    release: {
      version: '7.3.1',
      url: 'https://registry.npmjs.org/@oven/bun-linux-x64/-/bun-linux-x64-7.3.1.tgz',
      sha256: '20d515c5354423ecfc74411c4ea4d55aa29d35dce93641fe1e6c93acd9b5e63e',
    },
    script: `set -eu
curl -fsSL -o /opt/bun/bun.tgz https://registry.npmjs.org/@oven/bun-linux-x64/-/bun-linux-x64-7.3.1.tgz
echo "20d515c5354423ecfc74411c4ea4d55aa29d35dce93641fe1e6c93acd9b5e63e  /opt/bun/bun.tgz" | sha256sum -c - >/dev/null
${buildBunPinCheck('7.3.1')}
bun install --frozen-lockfile
`,
    printErr: (text) => {
      printed.push(text);
    },
  });

  expect({ exitCode, printed }).toStrictEqual({
    exitCode: 1,
    printed: [
      'check-preview-bun: https://registry.npmjs.org/@oven/bun-linux-x64/-/bun-linux-x64-7.3.1.tgz has sha256 c3a6dbb79f856999502c36ce5c5feb9fbdbd95f2764541cb52a9e9ae84038d70, but packages/preview/bun-release.ts pins 20d515c5354423ecfc74411c4ea4d55aa29d35dce93641fe1e6c93acd9b5e63e\n',
    ],
  });
});

test('it fails a release that the registry does not serve', async () => {
  server.use(
    http.get('https://registry.npmjs.org/@oven/bun-linux-x64/-/bun-linux-x64-7.3.1.tgz', () =>
      HttpResponse.json({ error: 'Not found' }, { status: 404 }),
    ),
  );

  const printed: string[] = [];

  const exitCode = await checkPreviewBun({
    release: {
      version: '7.3.1',
      url: 'https://registry.npmjs.org/@oven/bun-linux-x64/-/bun-linux-x64-7.3.1.tgz',
      sha256: '20d515c5354423ecfc74411c4ea4d55aa29d35dce93641fe1e6c93acd9b5e63e',
    },
    script: `set -eu
curl -fsSL -o /opt/bun/bun.tgz https://registry.npmjs.org/@oven/bun-linux-x64/-/bun-linux-x64-7.3.1.tgz
echo "20d515c5354423ecfc74411c4ea4d55aa29d35dce93641fe1e6c93acd9b5e63e  /opt/bun/bun.tgz" | sha256sum -c - >/dev/null
${buildBunPinCheck('7.3.1')}
bun install --frozen-lockfile
`,
    printErr: (text) => {
      printed.push(text);
    },
  });

  expect({ exitCode, printed }).toStrictEqual({
    exitCode: 1,
    printed: [
      'check-preview-bun: cannot download https://registry.npmjs.org/@oven/bun-linux-x64/-/bun-linux-x64-7.3.1.tgz: HTTP 404\n',
    ],
  });
});

test('it fails a script that installs the dependencies before it checks the repository pin', async () => {
  server.use(
    http.get(
      'https://registry.npmjs.org/@oven/bun-linux-x64/-/bun-linux-x64-7.3.1.tgz',
      () => new HttpResponse('stand-in bun tarball'),
    ),
  );

  const printed: string[] = [];

  const exitCode = await checkPreviewBun({
    release: {
      version: '7.3.1',
      url: 'https://registry.npmjs.org/@oven/bun-linux-x64/-/bun-linux-x64-7.3.1.tgz',
      sha256: '20d515c5354423ecfc74411c4ea4d55aa29d35dce93641fe1e6c93acd9b5e63e',
    },
    script: `set -eu
curl -fsSL -o /opt/bun/bun.tgz https://registry.npmjs.org/@oven/bun-linux-x64/-/bun-linux-x64-7.3.1.tgz
echo "20d515c5354423ecfc74411c4ea4d55aa29d35dce93641fe1e6c93acd9b5e63e  /opt/bun/bun.tgz" | sha256sum -c - >/dev/null
bun install --frozen-lockfile
${buildBunPinCheck('7.3.1')}
`,
    printErr: (text) => {
      printed.push(text);
    },
  });

  expect({ exitCode, printed }).toStrictEqual({
    exitCode: 1,
    printed: [
      "check-preview-bun: the contract script lacks the install after the check of the repository's pin against Bun 7.3.1\n",
    ],
  });
});

test('it fails a script that checks the repository pin against another release than it downloads', async () => {
  server.use(
    http.get(
      'https://registry.npmjs.org/@oven/bun-linux-x64/-/bun-linux-x64-7.3.1.tgz',
      () => new HttpResponse('stand-in bun tarball'),
    ),
  );

  const printed: string[] = [];

  const exitCode = await checkPreviewBun({
    release: {
      version: '7.3.1',
      url: 'https://registry.npmjs.org/@oven/bun-linux-x64/-/bun-linux-x64-7.3.1.tgz',
      sha256: '20d515c5354423ecfc74411c4ea4d55aa29d35dce93641fe1e6c93acd9b5e63e',
    },
    script: `set -eu
curl -fsSL -o /opt/bun/bun.tgz https://registry.npmjs.org/@oven/bun-linux-x64/-/bun-linux-x64-7.3.1.tgz
echo "20d515c5354423ecfc74411c4ea4d55aa29d35dce93641fe1e6c93acd9b5e63e  /opt/bun/bun.tgz" | sha256sum -c - >/dev/null
${buildBunPinCheck('7.2.0')}
bun install --frozen-lockfile
`,
    printErr: (text) => {
      printed.push(text);
    },
  });

  expect({ exitCode, printed }).toStrictEqual({
    exitCode: 1,
    printed: [
      "check-preview-bun: the contract script lacks the check of the repository's pin against Bun 7.3.1 after the check of its sha256 20d515c5354423ecfc74411c4ea4d55aa29d35dce93641fe1e6c93acd9b5e63e\n",
    ],
  });
});
