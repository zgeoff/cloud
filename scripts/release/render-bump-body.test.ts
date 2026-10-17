import { expect, test } from 'bun:test';
import { getReleaseRecord } from '../test-utils/get-release-record.ts';
import { renderBumpBody } from './render-bump-body.ts';

test('it says a bump that merges on its own does so once its checks pass', () => {
  expect(
    renderBumpBody({
      record: getReleaseRecord('auto-mode'),
      version: '0.19.4',
      pinned: ['0.19.3'],
      labels: ['update:patch', 'auto-merge'],
    }),
  ).toBe(
    'Bumps auto-mode to [0.19.4](https://github.com/zgeoff/auto-mode/releases/tag/auto-mode-v0.19.4). The release check opened this pull request.\n\n| Pin | From | To |\n| --- | --- | --- |\n| the agent image (`images/agent/Dockerfile`) | 0.19.3 | 0.19.4 |\n\nIt merges on its own once every check on its head passes, including the NixOS checks when it changes `nixos/`.\n\nAfter the merge: Rebuild the agent image (`docs/runbooks/agent-image.md`). Gateway sessions load the new mod from `/opt/auto-mode/mods/auto-mode` once they start on the new image.\n',
  );
});

test('it links an atc tag with its at signs encoded and gives a major release as the reason', () => {
  expect(
    renderBumpBody({
      record: getReleaseRecord('atc'),
      version: '5.0.0',
      pinned: ['4.2.0', '4.2.0', '4.2.0'],
      labels: ['update:major', 'needs-review'],
    }),
  ).toBe(
    "Bumps atc to [5.0.0](https://github.com/zgeoff/atc/releases/tag/%40zgeoff/atc%405.0.0). The release check opened this pull request.\n\n| Pin | From | To |\n| --- | --- | --- |\n| the agent image (`images/agent/Dockerfile`) | 4.2.0 | 5.0.0 |\n| the host's atc daemon (`nixos/packages/atc.nix`) | 4.2.0 | 5.0.0 |\n| the atc-gateway images (`images/atc-gateway/versions.env`) | 4.2.0 | 5.0.0 |\n\nIt waits for a review, because:\n\n- it is a major release.\n\nAfter the merge: Rebuild the agent image (`docs/runbooks/agent-image.md`). The atc-gateway images workflow publishes the gateway images and opens the pull request that pins their digests, which the `Deploy prod` workflow applies once it merges (`docs/runbooks/prod-apply.md`). Then switch the host (`docs/runbooks/workflows.md`), which refuses while the deployed gateway runs another atc major than the daemon pin.\n",
  );
});

test('it gives a minor release of a 0.x dependency as the reason', () => {
  expect(
    renderBumpBody({
      record: getReleaseRecord('nixie'),
      version: '0.8.0',
      pinned: ['0.7.2', '0.7.2'],
      labels: ['update:minor', 'needs-review'],
    }),
  ).toBe(
    'Bumps nixie to [0.8.0](https://github.com/zgeoff/nixie/releases/tag/v0.8.0). The release check opened this pull request.\n\n| Pin | From | To |\n| --- | --- | --- |\n| nixie (`infra/Pulumi.prod.yaml`) | 0.7.2 | 0.8.0 |\n| nixie-web (`infra/Pulumi.prod.yaml`) | 0.7.2 | 0.8.0 |\n\nIt waits for a review, because:\n\n- it is a minor release of a 0.x dependency, which may break.\n\nAfter the merge: The `Deploy prod` workflow applies the stack config once CI passes on main, unless its guard holds the plan (`docs/runbooks/prod-apply.md`). Check the deploy (`docs/runbooks/nixie.md`).\n',
  );
});

test('it gives no reason for a minor release from 1.0 on', () => {
  expect(
    renderBumpBody({
      record: getReleaseRecord('nixie'),
      version: '1.3.0',
      pinned: ['1.2.0', '1.2.0'],
      labels: ['update:minor', 'migrations', 'needs-review'],
    }),
  ).toBe(
    'Bumps nixie to [1.3.0](https://github.com/zgeoff/nixie/releases/tag/v1.3.0). The release check opened this pull request.\n\n| Pin | From | To |\n| --- | --- | --- |\n| nixie (`infra/Pulumi.prod.yaml`) | 1.2.0 | 1.3.0 |\n| nixie-web (`infra/Pulumi.prod.yaml`) | 1.2.0 | 1.3.0 |\n\nIt waits for a review, because:\n\n- a release in the bump adds database migrations, which a revert does not undo.\n\nAfter the merge: The `Deploy prod` workflow applies the stack config once CI passes on main, unless its guard holds the plan (`docs/runbooks/prod-apply.md`). Check the deploy (`docs/runbooks/nixie.md`).\n',
  );
});

test('it gives changed sandbox images as the reason', () => {
  expect(
    renderBumpBody({
      record: getReleaseRecord('nixie'),
      version: '0.7.3',
      pinned: ['0.7.2', '0.7.2'],
      labels: ['update:patch', 'sandbox-images-changed', 'needs-review'],
    }),
  ).toBe(
    "Bumps nixie to [0.7.3](https://github.com/zgeoff/nixie/releases/tag/v0.7.3). The release check opened this pull request.\n\n| Pin | From | To |\n| --- | --- | --- |\n| nixie (`infra/Pulumi.prod.yaml`) | 0.7.2 | 0.7.3 |\n| nixie-web (`infra/Pulumi.prod.yaml`) | 0.7.2 | 0.7.3 |\n\nIt waits for a review, because:\n\n- the release changes nixie's sandbox images, which a person adds to impd before the merge, because the `Deploy prod` workflow applies the merged pin (`docs/runbooks/nixie.md`).\n\nAfter the merge: The `Deploy prod` workflow applies the stack config once CI passes on main, unless its guard holds the plan (`docs/runbooks/prod-apply.md`). Check the deploy (`docs/runbooks/nixie.md`).\n",
  );
});

test('it marks a pin at the version or newer as unchanged', () => {
  expect(
    renderBumpBody({
      record: getReleaseRecord('imp'),
      version: '1.0.1',
      pinned: ['1.0.0', '1.0.2'],
      labels: ['update:patch', 'auto-merge'],
    }),
  ).toBe(
    "Bumps imp to [1.0.1](https://github.com/zgeoff/impz/releases/tag/v1.0.1). The release check opened this pull request.\n\n| Pin | From | To |\n| --- | --- | --- |\n| imp's NixOS module and the imp-host image (`nixos/`) | 1.0.0 | 1.0.1 |\n| the imp-base image (`images/agent/Dockerfile`) | 1.0.2 | unchanged |\n\nIt merges on its own once every check on its head passes, including the NixOS checks when it changes `nixos/`.\n\nAfter the merge: Copy impd's database, then switch the host, as `docs/runbooks/workflows.md` (Upgrade imp) describes; rebuild the agent image for imp-base (`docs/runbooks/agent-image.md`).\n",
  );
});
