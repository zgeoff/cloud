// polls until the condition holds, so a test waits on a state rather than a fixed sleep
export async function waitForCondition(
  condition: () => boolean,
  options: { readonly timeoutMs?: number } = {},
): Promise<void> {
  const deadline = Date.now() + (options.timeoutMs ?? 5000);

  while (!condition()) {
    if (Date.now() > deadline) {
      throw new Error('the condition did not hold before the wait timed out');
    }

    await Bun.sleep(10);
  }
}
