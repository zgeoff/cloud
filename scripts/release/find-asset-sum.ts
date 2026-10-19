export function findAssetSum(sums: string, asset: string): string | Error {
  const lines = sums
    .split('\n')
    .filter((line) => /^\S+ [ *](?<name>.+)$/u.exec(line)?.groups?.['name'] === asset);

  if (lines.length !== 1) {
    return new Error(`SHA256SUMS has ${lines.length} ${asset} lines, want 1`);
  }

  const sum = /^(?<sum>[0-9a-f]{64}) [ *]\S+$/u.exec(lines[0] ?? '')?.groups?.['sum'];

  return sum ?? new Error(`SHA256SUMS's ${asset} line holds no sha256 sum`);
}
