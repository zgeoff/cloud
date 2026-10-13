// What infra needs to deploy the Worker: its binding names, the schema of its targets and the
// path of its entry module. The Worker itself imports the modules, never this file, so the entry
// path stays out of its bundle.
export { bindingNames } from './binding-names.ts';
export { entryPath } from './entry-path.ts';
export { targetsSchema } from './targets-schema.ts';
export type { Target } from './targets-schema.ts';
