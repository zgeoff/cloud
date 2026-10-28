import { Command } from '@pulumi/command/local';
import type { Output } from '@pulumi/pulumi';
import { Acl, TailnetKey } from '@pulumi/tailscale';
import { topology } from '@zgeoff/cloud-topology';
import { tailnetPolicy } from './tailnet-policy.ts';

interface TailnetOutputs {
  readonly tailnetPolicyID: Output<string>;
  readonly hostAuthKey: Output<string>;
  readonly impKeySyncID: Output<string>;
  readonly impHostAuthKey: Output<string>;
}

export function createTailnet(): TailnetOutputs {
  // CAUTION: this resource owns the whole tailnet policy file
  const policy = new Acl('tailnet-policy', {
    acl: JSON.stringify(tailnetPolicy, null, 2),
    overwriteExistingContent: true,
  });

  const hostKey = createHostKey(policy);
  const impKeySync = createImpKeySync(policy);
  const impHostKey = createImpHostKey(policy);

  return {
    tailnetPolicyID: policy.id,
    hostAuthKey: hostKey.key,
    impKeySyncID: impKeySync.id,
    impHostAuthKey: impHostKey.key,
  };
}

function createHostKey(policy: Acl): TailnetKey {
  // Single-use; the node keeps its identity in /var/lib/tailscale.
  const hostKey = new TailnetKey(
    'geoffcloud-host',
    {
      description: 'geoffcloud host join',
      tags: [topology.tailnet.tags.cloud],
      reusable: false,
      ephemeral: false,
      preauthorized: true,
      expiry: 7 * 24 * 60 * 60,

      // single use: the host joined once, so the key reads as used. 'always' would mint a
      // fresh key on every apply and show as drift on every preview. A reinstall that needs
      // a new key replaces this resource on purpose (`pulumi up --replace`).
      recreateIfInvalid: 'never',
    },
    { dependsOn: [policy] },
  );

  return hostKey;
}

function createImpKeySync(policy: Acl): Command {
  // Tailscale's 90-day maximum expiry; an apply after expiry mints a fresh one, which Pulumi writes
  // into op://cloud/imp-tailscale-authkey.
  const impKey = new TailnetKey(
    'imp',
    {
      description: 'impd nodes',
      tags: [topology.tailnet.tags.imp],
      reusable: true,
      ephemeral: true,
      preauthorized: true,
      expiry: 90 * 24 * 60 * 60,
      recreateIfInvalid: 'always',
    },
    { dependsOn: [policy] },
  );

  const impKeySync = new Command('imp-key-to-1password', {
    // op treats a piped stdin as a JSON template, so read the key first
    create:
      'key=$(cat) && op item edit imp-tailscale-authkey --vault cloud "credential=$key" < /dev/null > /dev/null',
    stdin: impKey.key,
    triggers: [impKey.id],
    logging: 'none',
  });

  return impKeySync;
}

function createImpHostKey(policy: Acl): TailnetKey {
  // imp's node on geoffcloud is long-lived, so it must not be ephemeral: Tailscale
  // removes an offline ephemeral node, and a long reboot would lose imp-geoffcloud.
  // Single-use, for the reinstall only; tank/imp keeps the node state after that.
  const impHostKey = new TailnetKey(
    topology.tailnet.nodes.imp.hostname,
    {
      description: 'imp node on geoffcloud',
      tags: [topology.tailnet.tags.imp],
      reusable: false,
      ephemeral: false,
      preauthorized: true,
      expiry: 7 * 24 * 60 * 60,

      // as for the host's key: a reinstall replaces it on purpose (runbook step 3)
      recreateIfInvalid: 'never',
    },
    { dependsOn: [policy] },
  );

  return impHostKey;
}
