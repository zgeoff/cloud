import { expect, onTestFinished, test } from 'bun:test';
import { readFile, stat } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { createCloudCheckout } from './create-cloud-checkout.ts';

test('it clones an origin whose main holds the files', async () => {
  const checkout = await createCloudCheckout({
    'images/agent/Dockerfile': 'ARG EXAMPLE_VERSION=1.2.3\n',
    'infra/stack.yaml': 'example: true\n',
  });

  const tree = await checkout.git([
    `--git-dir=${checkout.origin}`,
    'ls-tree',
    '-r',
    '--name-only',
    'main',
  ]);

  const cloned = await readFile(join(checkout.clone, 'images/agent/Dockerfile'), 'utf8');

  expect(tree).toBe('images/agent/Dockerfile\ninfra/stack.yaml');
  expect(cloned).toBe('ARG EXAMPLE_VERSION=1.2.3\n');
});

test('it removes its directory once the test finishes', async () => {
  const checkout = await createCloudCheckout({ 'notes.txt': 'kept until the end\n' });

  const dir = dirname(checkout.clone);

  onTestFinished(async () => {
    const isKept = await Bun.file(join(dir, 'clone/notes.txt')).exists();

    expect(isKept).toBe(false);
  });

  const before = await stat(dir);

  expect(before.isDirectory()).toBe(true);
});
