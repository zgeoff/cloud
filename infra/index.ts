import { R2Bucket, getZoneOutput } from '@pulumi/cloudflare';
import { Acl } from '@pulumi/tailscale';
import { tailnetPolicy } from './tailnet-policy.ts';

const accountID = process.env['CLOUDFLARE_ACCOUNT_ID'];

if (accountID === undefined) {
  throw new Error('CLOUDFLARE_ACCOUNT_ID is unset; run through `op run --env-file=../.env`');
}

export const domain = 'geoff.cloud';
const zone = getZoneOutput({ filter: { name: domain } });

export const zoneID = zone.zoneId;

// restic repositories for imp and the k3s datastore snapshots (#9)
const backups = new R2Bucket('backups', {
  accountId: accountID,
  name: 'geoff-cloud-backups',
  location: 'oc',
});

export const backupsBucket = backups.name;

// CAUTION: this resource owns the whole tailnet policy file (#5)
const policy = new Acl('tailnet-policy', {
  acl: JSON.stringify(tailnetPolicy, null, 2),
  overwriteExistingContent: true,
});

export const tailnetPolicyID = policy.id;
