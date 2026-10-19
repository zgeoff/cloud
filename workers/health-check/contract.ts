// The Worker itself imports the modules, never this file, so the entry path stays out of its
// bundle.
export { bindingNames } from './binding-names.ts';
export { entryPath } from './entry-path.ts';
export { targetsSchema } from './targets-schema.ts';
export type { Target } from './targets-schema.ts';
