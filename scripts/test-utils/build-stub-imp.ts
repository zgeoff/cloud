import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import type { StubAnswer, StubCall, StubHandler } from './build-stub-runner.ts';

interface StubImpImage {
  readonly name: string;
  readonly digest: string;

  readonly isPinned?: boolean;
}

interface StubImpInstance {
  readonly name: string;
  readonly image: string;
}

export interface StubImpScenario {
  readonly images: readonly StubImpImage[];
  readonly imps?: readonly StubImpInstance[];

  readonly buildError?: string;

  readonly buildTimesOut?: boolean;
}

export interface StubImp {
  readonly handler: StubHandler;

  readonly images: readonly StubImpImage[];
  readonly imps: readonly StubImpInstance[];

  readonly builtDockerfiles: readonly string[];
}

interface StubImpState {
  readonly scenario: Readonly<StubImpScenario>;
  readonly images: StubImpImage[];
  readonly imps: StubImpInstance[];
  readonly builtDockerfiles: string[];
}

export function buildStubImp(scenario: Readonly<StubImpScenario>): StubImp {
  const state: StubImpState = {
    scenario,
    images: [...scenario.images],
    imps: [...(scenario.imps ?? [])],
    builtDockerfiles: [],
  };

  return {
    handler: (call) => (call.argv[0] === 'impz' ? buildImpAnswer(state, call) : undefined),
    images: state.images,
    imps: state.imps,
    builtDockerfiles: state.builtDockerfiles,
  };
}

type ImpCommand = (
  state: StubImpState,
  args: readonly string[],
) => StubAnswer | Promise<StubAnswer>;

const impCommands: readonly (readonly [string, ImpCommand])[] = [
  ['image ls --json', buildImageList],
  ['image build * --name *', (state, args) => runBuild(state, args[2] ?? '', args[4] ?? '')],
  ['image rm *', (state, args) => removeImage(state, args[2] ?? '')],
  ['image pin *', (state, args) => pinImage(state, args[2] ?? '')],
  ['new * --image *', (state, args) => createImp(state, args[1] ?? '', args[3] ?? '')],
  ['ls --json', (state) => ({ stdout: `${JSON.stringify(state.imps)}\n` })],
  ['rm *', (state, args) => removeImp(state, args[1] ?? '')],
];

function buildImpAnswer(state: StubImpState, call: StubCall): StubAnswer | Promise<StubAnswer> {
  const args = call.argv.slice(1);
  const command = impCommands.find(([shape]) => isShapeOf(shape, args));

  if (command === undefined) {
    return { exitCode: 97, stderr: `unexpected: ${JSON.stringify(call.argv)}\n` };
  }

  return command[1](state, args);
}

function buildImageList(state: StubImpState): StubAnswer {
  // only the fields of the real `image ls --json` output that the scripts read
  const images = state.images.map((image) => ({
    name: image.name,
    ref: `imp/${image.name}:latest`,
    digest: image.digest,
  }));

  return { stdout: `${JSON.stringify(images)}\n` };
}

async function runBuild(state: StubImpState, directory: string, name: string): Promise<StubAnswer> {
  const dockerfile = await readFile(join(directory, 'Dockerfile'), 'utf8');

  state.builtDockerfiles.push(dockerfile);

  if (state.scenario.buildTimesOut === true) {
    return { exitCode: 143, timedOut: true };
  }

  if (state.scenario.buildError !== undefined) {
    return { exitCode: 1, stderr: `${state.scenario.buildError}\n` };
  }

  state.images.push({ name, digest: `imp-build-stub-${name}` });

  return {};
}

function removeImage(state: StubImpState, name: string): StubAnswer {
  const index = state.images.findIndex((image) => image.name === name);

  if (index === -1) {
    // imp 0.38.1's NOT_FOUND answer, checked against the geoffcloud host; the CONFLICT messages
    // were not reproduced, and the scripts read only exit codes
    return { exitCode: 1, stderr: `impz: NOT_FOUND: image ${name} not found\n` };
  }

  if (state.imps.some((imp) => imp.image === name)) {
    return { exitCode: 1, stderr: `impz: CONFLICT: image ${name} is in use\n` };
  }

  state.images.splice(index, 1);

  return {};
}

function pinImage(state: StubImpState, name: string): StubAnswer {
  const index = state.images.findIndex((image) => image.name === name);
  const image = state.images[index];

  if (image === undefined) {
    // imp 2.10.1's pin answers a missing name with the NOT_FOUND an rm gives
    // (packages/daemon/src/imps/images/image-service.ts in zgeoff/impz); a pin prints nothing
    return { exitCode: 1, stderr: `impz: NOT_FOUND: image ${name} not found\n` };
  }

  state.images[index] = { ...image, isPinned: true };

  return {};
}

function createImp(state: StubImpState, name: string, image: string): StubAnswer {
  if (!state.images.some((record) => record.name === image)) {
    return { exitCode: 1, stderr: `impz: NOT_FOUND: image ${image} not found\n` };
  }

  if (state.imps.some((imp) => imp.name === name)) {
    return { exitCode: 1, stderr: `impz: CONFLICT: imp ${name} already exists\n` };
  }

  state.imps.push({ name, image });

  return { stdout: `${name}\n` };
}

function removeImp(state: StubImpState, name: string): StubAnswer {
  const index = state.imps.findIndex((imp) => imp.name === name);

  if (index === -1) {
    return { exitCode: 1, stderr: `impz: NOT_FOUND: imp ${name} not found\n` };
  }

  state.imps.splice(index, 1);

  return {};
}

function isShapeOf(shape: string, args: readonly string[]) {
  const words = shape.split(' ');

  return (
    words.length === args.length &&
    words.every((word, index) => word === '*' || word === args[index])
  );
}
