import type { ProbeTarget } from './build-tcp-probe.ts';
import { buildTCPProbe } from './build-tcp-probe.ts';
import { findFetchImage } from './find-fetch-image.ts';
import type { ProbeAnswer } from './format-probe-answer.ts';
import { formatProbeAnswer } from './format-probe-answer.ts';
import type { RemoteResult, SandboxTarget } from './load-sandbox-targets.ts';
import { loadSandboxTargets } from './load-sandbox-targets.ts';
import { parseTailnetTarget } from './parse-tailnet-target.ts';
import { toShellArg } from './to-shell-arg.ts';

// Checks, after a deploy, that a fetch sandbox on nixie's fetch image reaches a public page and no
// address inside the cloud. It creates one imp under imp's public egress policy, as nixie does for
// its web fetch tool, probes from it, and removes it; it reads nixie's pod and changes nothing else.
export interface CheckFetchSandboxOptions {
  readonly args: readonly string[];

  // the imp's name; outside nixie-*, so nixie's sandbox recovery never takes it for its own
  readonly sandboxName: string;

  // runs one command line as root on geoffcloud; the line lands in the host's journal, so it never
  // carries a secret
  readonly runRemote: (command: string) => Promise<RemoteResult>;
  readonly printOut: (text: string) => void;
  readonly printErr: (text: string) => void;
}

const usage = 'usage: bun run nixie:check-sandbox <tailnet address>:<port>\n';

// Runs the check and returns the exit code: 0 when it passes, 1 when it fails, 2 on bad arguments
export async function checkNixieFetchSandbox(
  options: Readonly<CheckFetchSandboxOptions>,
): Promise<number> {
  const tailnet = parseTailnetTarget(options.args);

  if (!tailnet.ok) {
    options.printErr(`check-nixie-fetch-sandbox: ${tailnet.error}\n${usage}`);

    return 2;
  }

  const plan = await loadPlan(options, tailnet.target);

  return plan === undefined ? 1 : runSandboxCheck(options, plan);
}

// Removes the sandbox once it exists, whatever the probes found and even when a probe throws
async function runSandboxCheck(
  options: Readonly<CheckFetchSandboxOptions>,
  plan: Plan,
): Promise<number> {
  const created = await createSandbox(options, plan.image);

  if (!created) {
    return 1;
  }

  const passed = await checkSandbox(options, plan).catch((error: unknown) => {
    options.printErr(`check-nixie-fetch-sandbox: the check stopped: ${String(error)}\n`);

    return false;
  });

  const removed = await removeSandbox(options);

  if (!passed || !removed) {
    return 1;
  }

  options.printOut('fetch sandbox check passed\n');

  return 0;
}

interface Plan {
  readonly image: string;
  readonly targets: readonly SandboxTarget[];
}

// Reads only, and stops before the sandbox exists unless every target answers the host: a
// target with no listener refuses every network alike, so the sandbox's refusal would prove nothing
async function loadPlan(
  options: Readonly<CheckFetchSandboxOptions>,
  tailnet: ProbeTarget,
): Promise<Plan | undefined> {
  const image = await readFetchImage(options);

  const loaded =
    image === undefined ? undefined : await loadSandboxTargets(options.runRemote, tailnet);

  if (loaded?.ok === false) {
    options.printErr(`check-nixie-fetch-sandbox: ${loaded.error}\n`);
  }

  if (image === undefined || loaded?.ok !== true) {
    return undefined;
  }

  options.printOut(`fetch image: ${image}\n`);

  const answered = await checkHostReaches(options, loaded.targets);

  return answered ? { image, targets: loaded.targets } : undefined;
}

async function checkHostReaches(
  options: Readonly<CheckFetchSandboxOptions>,
  targets: readonly SandboxTarget[],
): Promise<boolean> {
  const answers = await Promise.all(
    targets.map((target) => runProbe(options, { target, command: buildTCPProbe(target) })),
  );

  printProbes(options, 'from the host', answers);

  if (answers.every((answer) => answer.status === 0)) {
    return true;
  }

  options.printErr(
    'check-nixie-fetch-sandbox: a target does not answer from the host, so a refusal from the sandbox would prove nothing\n',
  );

  return false;
}

const manifestCommand = 'k3s kubectl -n nixie exec nixie-0 -c nixie -- nixie sandbox-manifest';

async function readFetchImage(
  options: Readonly<CheckFetchSandboxOptions>,
): Promise<string | undefined> {
  const manifest = await options.runRemote(manifestCommand);

  const image = manifest.exitCode === 0 ? findFetchImage(manifest.stdout) : undefined;

  if (image === undefined) {
    options.printErr(
      `check-nixie-fetch-sandbox: cannot read the fetch image from nixie's sandbox manifest: ${manifest.stderr.trim()}\n`,
    );
  }

  return image;
}

interface Probe {
  readonly target: SandboxTarget;
  readonly command: string;
}

async function runProbe(
  options: Readonly<CheckFetchSandboxOptions>,
  probe: Probe,
): Promise<ProbeAnswer> {
  const result = await options.runRemote(probe.command);

  const status = /^probe-exit:(?<status>\d+)$/mu.exec(result.stdout)?.groups?.['status'];

  return { target: probe.target, status: status === undefined ? null : Number(status) };
}

function printProbes(
  options: Readonly<CheckFetchSandboxOptions>,
  from: string,
  answers: readonly ProbeAnswer[],
): void {
  for (const answer of answers) {
    options.printOut(`${from}: ${formatProbeAnswer(answer)}\n`);
  }
}

const impCommand = 'docker exec imp-host impz';

// A failed create can still leave the imp, so the error names it for impz ls
async function createSandbox(
  options: Readonly<CheckFetchSandboxOptions>,
  image: string,
): Promise<boolean> {
  const created = await options.runRemote(
    `${impCommand} new ${options.sandboxName} --image ${image} --policy public`,
  );

  if (created.exitCode !== 0) {
    options.printErr(
      `check-nixie-fetch-sandbox: cannot create sandbox ${options.sandboxName}: ${created.stderr.trim()}; look for it with impz ls\n`,
    );

    return false;
  }

  options.printOut(`created sandbox ${options.sandboxName} on ${image}, policy public\n`);

  return true;
}

async function checkSandbox(
  options: Readonly<CheckFetchSandboxOptions>,
  plan: Plan,
): Promise<boolean> {
  const reached = await checkPublicPage(options);

  const answers = await Promise.all(
    plan.targets.map((target) =>
      runProbe(options, { target, command: buildSandboxCommand(options, buildTCPProbe(target)) }),
    ),
  );

  printProbes(options, 'from the sandbox', answers);

  return printReached(options, answers) && reached;
}

function buildSandboxCommand(options: Readonly<CheckFetchSandboxOptions>, command: string): string {
  return `${impCommand} exec ${options.sandboxName} -- bash -c ${toShellArg(command)}`;
}

const pageScript =
  'const page = await fetch("https://example.com/"); console.log(page.status, (await page.text()).includes("Example Domain"));';

async function checkPublicPage(options: Readonly<CheckFetchSandboxOptions>): Promise<boolean> {
  const result = await options.runRemote(
    buildSandboxCommand(options, `/usr/local/bin/bun -e ${toShellArg(pageScript)}`),
  );

  const answer = result.stdout.trim();

  options.printOut(
    `public page: https://example.com/ answered ${answer === '' ? 'nothing' : answer}\n`,
  );

  if (answer === '200 true') {
    return true;
  }

  options.printErr(
    `check-nixie-fetch-sandbox: the sandbox did not read https://example.com/: ${result.stderr.trim()}\n`,
  );

  return false;
}

function printReached(
  options: Readonly<CheckFetchSandboxOptions>,
  answers: readonly ProbeAnswer[],
): boolean {
  const failures = answers.filter((answer) => answer.status !== 1 && answer.status !== 124);

  for (const answer of failures) {
    options.printErr(
      `check-nixie-fetch-sandbox: the sandbox's probe of ${formatProbeAnswer(answer)}\n`,
    );
  }

  return failures.length === 0;
}

async function removeSandbox(options: Readonly<CheckFetchSandboxOptions>): Promise<boolean> {
  const removed = await options.runRemote(`${impCommand} rm ${options.sandboxName}`);

  if (removed.exitCode !== 0) {
    options.printErr(
      `check-nixie-fetch-sandbox: cannot remove sandbox ${options.sandboxName}: ${removed.stderr.trim()}; remove it with impz rm\n`,
    );

    return false;
  }

  options.printOut(`removed sandbox ${options.sandboxName}\n`);

  return true;
}

async function runSSH(command: string): Promise<RemoteResult> {
  const proc = Bun.spawn(['ssh', 'root@geoffcloud', command], {
    stdin: 'ignore',
    stdout: 'pipe',
    stderr: 'pipe',
  });

  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);

  return { exitCode, stdout, stderr };
}

if (import.meta.main) {
  process.exitCode = await checkNixieFetchSandbox({
    args: process.argv.slice(2),
    sandboxName: `fetch-check-${crypto.randomUUID().slice(0, 8)}`,
    runRemote: runSSH,
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}
