import { expect, test } from 'bun:test';
import { buildStubOp } from './build-stub-op.ts';
import { buildStubRunner } from './build-stub-runner.ts';

test('it lists a vault’s items as op’s item JSON', async () => {
  const op = buildStubOp({ vaults: { cloud: { 'atc-daemon-token': 'fixture-bearer' } } });
  const stub = buildStubRunner(op.handle);

  const result = await stub.run(['op', 'item', 'list', '--vault', 'cloud', '--format', 'json']);

  expect(JSON.parse(result.stdout.toString())).toStrictEqual([
    {
      id: 'fixture-item-id',
      title: 'atc-daemon-token',
      version: 1,
      vault: { id: 'fixture-vault-id', name: 'cloud' },
      category: 'API_CREDENTIAL',
    },
  ]);
});

test('it saves the credential of an item created from stdin, and reads it back with a newline', async () => {
  const op = buildStubOp({ vaults: { cloud: {} } });
  const stub = buildStubRunner(op.handle);

  await stub.run(['op', 'item', 'create', '--vault', 'cloud', '-', '--format', 'json'], {
    stdin: Buffer.from(
      '{"title":"atc-daemon-token","category":"API_CREDENTIAL","fields":[{"id":"credential","type":"CONCEALED","label":"credential","value":"fixture-bearer"}]}',
    ),
  });

  const read = await stub.run(['op', 'read', 'op://cloud/atc-daemon-token/credential']);

  expect(op.vaults).toStrictEqual({ cloud: { 'atc-daemon-token': 'fixture-bearer' } });
  expect(read.stdout.toString()).toBe('fixture-bearer\n');
});

test('it fails op’s way for a vault that does not exist', async () => {
  const stub = buildStubRunner(buildStubOp({ vaults: {} }).handle);

  const result = await stub.run(['op', 'vault', 'get', 'missing', '--format', 'json']);

  expect(result.exitCode).toBe(1);

  expect(result.stderr.toString()).toBe(
    `[ERROR] 2026/10/07 12:00:00 "missing" isn't a vault in this account. Specify the vault with its ID or name.\n`,
  );
});

test('it fails a read of a missing item op’s way', async () => {
  const stub = buildStubRunner(buildStubOp({ vaults: { cloud: {} } }).handle);

  const result = await stub.run(['op', 'read', 'op://cloud/atc-daemon-token/credential']);

  expect(result.exitCode).toBe(1);

  expect(result.stderr.toString()).toBe(
    `[ERROR] 2026/10/07 12:00:00 could not read secret op://cloud/atc-daemon-token/credential: could not get item cloud/atc-daemon-token: "atc-daemon-token" isn't an item in the "cloud" vault.\n`,
  );
});

test('it fails the call the scenario names as a rate-limited op does, and saves nothing', async () => {
  const op = buildStubOp({ vaults: { cloud: {} }, failAt: 'item-create' });
  const stub = buildStubRunner(op.handle);

  const result = await stub.run(
    ['op', 'item', 'create', '--vault', 'cloud', '-', '--format', 'json'],
    {
      stdin: Buffer.from('{"title":"atc-daemon-token","fields":[]}'),
    },
  );

  expect(result.exitCode).toBe(1);

  expect(result.stderr.toString()).toStartWith(
    '[ERROR] 2026/10/07 12:00:00 (429) Too Many Requests',
  );

  expect(op.vaults).toStrictEqual({ cloud: {} });
});

test('it records the service account token each call ran with', async () => {
  const op = buildStubOp({ vaults: { cloud: {} } });
  const stub = buildStubRunner(op.handle);

  await stub.run(['op', 'vault', 'get', 'cloud', '--format', 'json'], {
    env: { OP_SERVICE_ACCOUNT_TOKEN: 'ops_fixture' },
  });

  await stub.run(['op', 'vault', 'get', 'cloud', '--format', 'json']);

  expect(op.tokensSeen).toStrictEqual(['ops_fixture', undefined]);
});

test('it leaves a call to op it does not model to the next handler', async () => {
  const stub = buildStubRunner(buildStubOp({ vaults: {} }).handle);

  const result = await stub.run(['op', 'item', 'delete', 'atc-daemon-token']);

  expect(result.exitCode).toBe(97);
});
