import type { Output } from '@pulumi/pulumi';
import type { z } from 'zod';
import type { atcGatewayConfigSchema } from './atc-gateway-config-schema.ts';

// .env's values, resolved by `op run`
export type Environment = Readonly<Record<string, string | undefined>>;

// Pulumi Config's methods take a type argument that they never check, so these take none
export interface StackConfig {
  readonly get: (key: string) => string | undefined;
  readonly getBoolean: (key: string) => boolean | undefined;
  readonly getObject: (key: string) => unknown;
  readonly getSecret: (key: string) => Output<string> | undefined;
}

export type ATCGatewayRawConfig = z.input<typeof atcGatewayConfigSchema>;

export type ATCGatewayConfig = z.output<typeof atcGatewayConfigSchema>;

export type ATCGatewayDaemon = ATCGatewayConfig['daemons'][string];

export type ATCDaemonEndpoint = { readonly name: string } & Pick<
  ATCGatewayDaemon,
  'address' | 'alertSeverity'
>;

export interface ATCGatewayBackupSecrets {
  readonly repository: Output<string>;
  readonly password: Output<string>;
  readonly accessKeyID: Output<string>;
  readonly secretAccessKey: Output<string>;
}

// the GitHub login and classic read:packages token k3s pulls the private GHCR images with
export interface GHCRPullCredential {
  readonly username: string;
  readonly token: Output<string>;
}

export interface BackupImage {
  readonly reference: string;
  readonly pullCredential: GHCRPullCredential;
}

export interface ATCGatewayInputs {
  readonly config: ATCGatewayConfig;
  readonly secrets: {
    readonly pullCredential: GHCRPullCredential;

    // the bearer token the gateway presents to each daemon, by daemon name
    readonly tokens: Readonly<Record<string, Output<string>>>;

    // restic to R2; without it there is no backup CronJob
    readonly backup?: ATCGatewayBackupSecrets;

    // the one address the Access policy in front of the gateway's sign-in pages lets in
    readonly ownerEmail: Output<string>;

    // the fixed bearer token of each service client of /mcp, by client name. Present only while
    // the gateway image knows --service-token-file (atc 7.14.0 and later)
    readonly serviceTokens?: Readonly<Record<string, Output<string>>>;
  };
}

interface NixieConfig {
  // the nixie and nixie-web images of one release, each by tag and digest
  readonly image: string;
  readonly webImage: string;

  // the one public DNS name, which points at the host's tailnet address
  readonly hostname: string;
}

// a nightly job that ships the backup sets nixie stages: nixie.db to the data repo and keys.db to
// the key repo, both restic repos in nixie's own R2 bucket
export interface NixieBackupInputs {
  // the nixie-backup image of nixie's release, by tag and digest
  readonly image: string;
  readonly pullCredential: GHCRPullCredential;
  readonly secrets: {
    readonly dataRepository: Output<string>;
    readonly dataPassword: Output<string>;
    readonly keyRepository: Output<string>;
    readonly keyPassword: Output<string>;
    readonly accessKeyID: Output<string>;
    readonly secretAccessKey: Output<string>;
  };
}

export interface NixieInputs {
  readonly config: NixieConfig;
  readonly secrets: {
    // the host's age identity, which decrypts deploy/nixie/secrets.sops.yaml
    readonly ageHostKey: Output<string>;

    // git-sync's read-only deploy key for zgeoff/nixie-definitions
    readonly definitionsDeployKey: Output<string>;

    // Pulumi's own Cloudflare token, for the certificate's DNS-01 challenge
    readonly dnsToken: Output<string>;
  };

  // without it there is no backup CronJob
  readonly backup?: NixieBackupInputs;
}

interface FilesConfig {
  // by tag and digest
  readonly image: string;

  // the one public DNS name, which the tunnel serves
  readonly hostname: string;
}

// a nightly restic backup of the files service's volume to its own repository in R2
export interface FilesBackupInputs {
  readonly image: string;
  readonly secrets: {
    readonly repository: Output<string>;
    readonly password: Output<string>;
    readonly accessKeyID: Output<string>;
    readonly secretAccessKey: Output<string>;
  };
}

export interface FilesInputs {
  readonly config: FilesConfig;

  readonly pullCredential: GHCRPullCredential;

  // the SHA-256 of each role token, as hex; the cluster never holds a token
  readonly tokenHashes: {
    readonly agent: Output<string>;
    readonly owner: Output<string>;
  };

  // without it there is no backup CronJob
  readonly backup?: FilesBackupInputs;
}

// what the boxxy server's configuration file takes from the stack config; the cluster sets the
// listeners, the store and the rules folder itself
export interface BoxxyConfig {
  // by tag and digest
  readonly image: string;

  // the runner ID the server claims tasks as
  readonly runner: string;

  // the cluster sets the address: the atc gateway's Service
  readonly atc: {
    // by worker target: the folders the agent trusts
    readonly trustedFolders: Readonly<Record<string, readonly string[]>>;
  };
  readonly spawn: {
    readonly target: string;

    // the atc agents whose broker profile holds the read-only clone token: only a review recipe
    // may name one, and with one the server runs its review gate
    readonly reviewAgents?: readonly string[];
  };

  // with it, the server sends its facts to pepys and reads its two reports there; the cluster sets
  // the addresses
  readonly pepys?: { readonly environment: string };

  // with it, the server links and watches pull requests
  readonly github?: { readonly baseUrl: string };

  // with it, the server serves the owner's MCP tools on its public door, behind OAuth, through a
  // tunnel whose connector runs in the server's pod
  readonly publicDoor?: {
    // the https origin clients reach the door at: the OAuth issuer
    readonly publicURL: string;

    // the socket peers whose forwarded client address the door's security events trust
    readonly trustForwardedFrom: readonly string[];
  };
}

// by repo: its folder on the target, or the git source that atc clones there
export type BoxxyRepos = Readonly<Record<string, string | BoxxyGitSource>>;

// credentialRef names the atc daemon's environment variable that holds the clone token
interface BoxxyGitSource {
  readonly url: string;
  readonly ref: string;
  readonly credentialRef?: { readonly name: string };
}

// a nightly restic backup of the boxxy store to its own repository in R2, run by the atc gateway's
// backup image
export interface BoxxyBackupInputs {
  readonly image: string;
  readonly secrets: {
    readonly repository: Output<string>;
    readonly password: Output<string>;
    readonly accessKeyID: Output<string>;
    readonly secretAccessKey: Output<string>;
  };
}

export interface BoxxyInputs {
  readonly config: BoxxyConfig;

  // the server's spawn.repos, a secret: a private repo's name stays out of the preview
  readonly repos: Output<BoxxyRepos>;

  readonly pullCredential: GHCRPullCredential;
  readonly secrets: {
    // the bearer token the broker adds to every worker call; the worker listener checks it
    readonly workerToken: Output<string>;

    // the bearer token the server sends to the atc daemon
    readonly atcToken: Output<string>;

    // with config pepys: the key the server signs its fact batches with
    readonly pepysSigningSecret?: Output<string>;

    // with config github: the token of its pull request reads
    readonly githubToken?: Output<string>;

    // with review agents: the noslop App's keys, which the review gate checks and posts with
    readonly reviewApp?: {
      readonly appID: Output<string>;
      readonly privateKey: Output<string>;
      readonly installationID: Output<string>;
    };
  };

  // without it there is no backup CronJob
  readonly backup?: BoxxyBackupInputs;
}

export interface AlertWebhook {
  readonly url: string;

  // the Discord user a critical alert mentions, so the message pushes a notification
  readonly mentionUserID: string;
}

interface PepysConfig {
  // the cloud-pepys image, by tag and digest: ingest, the host and the API run its binaries
  readonly image: string;

  // the public DNS name of ingest's public routes, which the shared tunnel serves
  readonly webhookHostname: string;

  // the public DNS name of the API's /mcp and OAuth paths, which the shared tunnel serves; while it
  // is unset, the API serves /rpc alone and nothing of it is public
  readonly apiHostname?: string;

  // the audience that a telemetry sender's identity token must name; while it is unset, ingest
  // refuses every telemetry export
  readonly impIdentityAudience?: string;
}

// a nightly rclone copy of the Garage buckets to an R2 bucket
export interface PepysBackupInputs {
  readonly secrets: {
    readonly garageAccessKeyID: Output<string>;
    readonly garageSecretAccessKey: Output<string>;
    readonly r2Endpoint: Output<string>;
    readonly r2Bucket: Output<string>;
    readonly r2AccessKeyID: Output<string>;
    readonly r2SecretAccessKey: Output<string>;
  };
}

export interface PepysInputs {
  readonly config: PepysConfig;

  readonly pullCredential: GHCRPullCredential;

  readonly secrets: {
    readonly garageRPCSecret: Output<string>;
    readonly garageAdminToken: Output<string>;

    // s2-lite's key on the facts bucket, which Garage imports at its start
    readonly s2GarageAccessKeyID: Output<string>;
    readonly s2GarageSecretAccessKey: Output<string>;
    readonly s2AccessToken: Output<string>;

    // each secret that a route of the deployment checks, by the variable ingest reads
    readonly ingest: Readonly<Record<string, Output<string>>>;
  };

  // without it there is no backup CronJob
  readonly backup?: PepysBackupInputs;
}
