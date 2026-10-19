import type { StubAnswer, StubCall, StubHandler } from './build-stub-runner.ts';

export function buildStubGetent(hosts: Readonly<Record<string, string>>): StubHandler {
  return (call) => (call.argv[0] === 'getent' ? buildGetentAnswer(hosts, call) : undefined);
}

function buildGetentAnswer(hosts: Readonly<Record<string, string>>, call: StubCall): StubAnswer {
  const [, database, name = ''] = call.argv;

  if (database !== 'hosts' || call.argv.length !== 3) {
    return { exitCode: 97, stderr: `unexpected: ${JSON.stringify(call.argv)}\n` };
  }

  const address = hosts[name];

  // glibc 2.39's nss/getent.c prints a found host as printf("%-15s %s", address, name) and exits 2
  // for a key it cannot find
  return address === undefined ? { exitCode: 2 } : { stdout: `${address.padEnd(15)} ${name}\n` };
}
