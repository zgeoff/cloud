// A stand-in for `kubectl proxy --port=0`, run as its own program in the mode serve, refuse <error>
// or quiet. Its serving line is kubectl's, from pkg/cmd/proxy/proxy.go at v0.34.1, with the
// listener's address.
const [mode, error] = process.argv.slice(2);

if (mode === 'serve') {
  const server = Bun.serve({
    hostname: '127.0.0.1',
    port: 0,
    routes: { '/*': new Response('stub kubectl proxy') },
  });

  process.stdout.write(`Starting to serve on 127.0.0.1:${String(server.port)}\n`);
} else if (mode === 'refuse' && error !== undefined) {
  process.stderr.write(`${error}\n`);
  process.exit(1);
} else if (mode === 'quiet') {
  setInterval(() => {}, 60_000);
} else {
  process.stderr.write(`unexpected: ${JSON.stringify(process.argv.slice(2))}\n`);
  process.exit(97);
}
