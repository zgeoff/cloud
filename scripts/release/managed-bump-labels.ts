// every label the release bump manages, with its color and description
export const managedBumpLabels: ReadonlyMap<string, readonly [string, string]> = new Map([
  ['update:major', ['d73a4a', 'a major release']],
  ['update:minor', ['fbca04', 'a minor release']],
  ['update:patch', ['0e8a16', 'a patch release']],
  ['migrations', ['d73a4a', 'the release adds database migrations']],
  ['sandbox-images-changed', ['fbca04', "the release changes nixie's sandbox images"]],
  ['auto-merge', ['0e8a16', 'merges on its own once its checks pass']],
  ['needs-review', ['d73a4a', 'waits for a review before it merges']],
]);
