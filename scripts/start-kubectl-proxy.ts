export interface KubectlProxy {
  // the proxy's base URL, such as http://127.0.0.1:41873, with no trailing slash
  readonly url: string;

  readonly stop: () => Promise<void>;
}

export type KubectlProxyStart =
  | { readonly ok: true; readonly proxy: KubectlProxy }
  | { readonly ok: false; readonly error: string };

export interface StartKubectlProxyOptions {
  // kubectl proxy with --port=0, so the proxy takes a free port and prints it
  readonly argv: readonly string[];
  readonly timeoutMs: number;
}

export async function startKubectlProxy(
  options: Readonly<StartKubectlProxyOptions>,
): Promise<KubectlProxyStart> {
  const subprocess = Bun.spawn([...options.argv], {
    stdin: 'ignore',
    stdout: 'pipe',
    stderr: 'pipe',
  });

  const stop = async () => {
    subprocess.kill();

    await subprocess.exited;
  };

  const stderr = new Response(subprocess.stderr).text();

  const timer = Promise.withResolvers<null>();

  const timeout = setTimeout(() => {
    timer.resolve(null);
  }, options.timeoutMs);

  const address = await Promise.race([readAddress(subprocess.stdout), timer.promise]);

  clearTimeout(timeout);

  if (address !== null && address !== undefined) {
    return { ok: true, proxy: { url: `http://${address}`, stop } };
  }

  await stop();

  const errorOutput = await stderr;

  const detail = errorOutput.trim();

  return {
    ok: false,
    error:
      address === null
        ? `kubectl proxy printed no address within ${String(options.timeoutMs)} ms`
        : `kubectl proxy exited before it listened: ${detail === '' ? 'no error output' : detail}`,
  };
}

// kubectl proxy prints this line once it listens (kubectl's pkg/cmd/proxy/proxy.go, v0.34.1); the
// newline ends the match, so a chunk that ends inside the port never matches a shorter port
const servingPattern = /^Starting to serve on (?<address>127\.0\.0\.1:\d+)\n/mu;

// undefined when the output ends with no address, as it does when kubectl exits
async function readAddress(stdout: ReadableStream<Uint8Array>): Promise<string | undefined> {
  const decoder = new TextDecoder();

  let text = '';

  for await (const chunk of stdout) {
    text += decoder.decode(chunk, { stream: true });

    const address = servingPattern.exec(text)?.groups?.['address'];

    if (address !== undefined) {
      return address;
    }
  }

  return undefined;
}
