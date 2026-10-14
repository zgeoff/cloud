import type { StubHandler } from './build-stub-runner.ts';

// Stands in for `getent hosts <name>`, which would otherwise ask the machine's resolver and reach
// DNS. glibc 2.39's nss/getent.c prints a found host as printf("%-15s %s", address, name) and
// exits 2 for a key it cannot find.
export function buildStubGetent(hosts: Readonly<Record<string, string>>): StubHandler {
  return (call) => {
    const [program, database, name = ''] = call.argv;

    if (program !== 'getent') {
      return;
    }

    if (database !== 'hosts' || call.argv.length !== 3) {
      return { exitCode: 97, stderr: `unexpected: ${JSON.stringify(call.argv)}\n` };
    }

    const address = hosts[name];

    return address === undefined ? { exitCode: 2 } : { stdout: `${address.padEnd(15)} ${name}\n` };
  };
}
