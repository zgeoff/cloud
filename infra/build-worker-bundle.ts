// Bundles a Worker's entry module and its imports into one ESM file. With throw: false a
// failed build returns its reasons in logs; by default Bun.build throws an AggregateError
// whose message is only "Bundle failed".
export async function buildWorkerBundle(entrypoint: string): Promise<string> {
  const result = await Bun.build({
    entrypoints: [entrypoint],
    format: 'esm',
    target: 'browser',
    minify: false,
    throw: false,
  });

  const [output] = result.outputs;

  if (!result.success || output === undefined) {
    throw new Error(
      `bundle of ${entrypoint} failed: ${result.logs.map((log) => log.message).join('\n')}`,
    );
  }

  return output.text();
}
