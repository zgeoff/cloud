// an exited process shows Z until something reaps it, then X for a moment before its entry goes;
// neither holds a pipe
const exitedStates = new Set(['Z', 'X']);

export function isProcessStatAlive(stat: string): boolean {
  // the command name sits in parentheses and can hold a `)` itself, so the state follows the last one
  const state = stat.slice(stat.lastIndexOf(')') + 2, stat.lastIndexOf(')') + 3);

  return !exitedStates.has(state);
}
