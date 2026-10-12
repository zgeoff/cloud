// Quotes a value as one word for a POSIX shell, so a remote command line passes it through whole
export function toShellArg(value: string): string {
  return `'${value.replaceAll("'", `'\\''`)}'`;
}
