export function toShellArg(value: string): string {
  return `'${value.replaceAll("'", `'\\''`)}'`;
}
