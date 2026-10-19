export async function readWorkerBundle(entrypoint: string): Promise<string> {
  const result = await Bun.build({
    entrypoints: [entrypoint],
    format: 'esm',
    target: 'browser',
    minify: false,

    // By default Bun.build throws an AggregateError whose message is only "Bundle failed"; with
    // throw: false a failed build returns its reasons in logs.
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
