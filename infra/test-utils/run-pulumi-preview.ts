interface PulumiPreviewOptions {
  readonly pulumiPath: string;

  // the project directory, holding Pulumi.yaml
  readonly cwd: string;
  readonly env: Record<string, string>;

  // where the preview's stop goes, so it runs before the caller removes the project directory
  readonly cleanup: Pick<AsyncDisposableStack, 'defer'>;
}

// Runs `pulumi preview` on a project and returns its exit code and its stdout followed by its
// stderr. A preview still running when the test ends, as at a timeout, is killed and awaited.
export async function runPulumiPreview(
  options: PulumiPreviewOptions,
): Promise<{ exitCode: number; output: string }> {
  const preview = Bun.spawn([options.pulumiPath, 'preview', '--non-interactive'], {
    cwd: options.cwd,
    env: options.env,
    stdout: 'pipe',
    stderr: 'pipe',
  });

  options.cleanup.defer(async () => {
    preview.kill();

    await preview.exited;
  });

  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(preview.stdout).text(),
    new Response(preview.stderr).text(),
    preview.exited,
  ]);

  return { exitCode, output: stdout + stderr };
}
