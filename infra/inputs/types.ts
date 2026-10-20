import type { Output } from '@pulumi/pulumi';
import type { z } from 'zod';
import type { atcGatewayConfigSchema } from './atc-gateway-config-schema.ts';

// the process environment as index.ts reads it once: .env's values, resolved by `op run`
export type Environment = Readonly<Record<string, string | undefined>>;

// the stack config methods the inputs group reads: Pulumi's Config, or a stand-in in a test.
// Config's methods take a type argument that they never check, so these take none.
export interface StackConfig {
  readonly get: (key: string) => string | undefined;
  readonly getBoolean: (key: string) => boolean | undefined;
  readonly getObject: (key: string) => unknown;
  readonly getSecret: (key: string) => Output<string> | undefined;
}

// the atcGateway stack config as written, before the schema fills in each default
export type ATCGatewayRawConfig = z.input<typeof atcGatewayConfigSchema>;

// the atcGateway stack config once the schema has checked it
export type ATCGatewayConfig = z.output<typeof atcGatewayConfigSchema>;

// one daemon the gateway dials, checked
export type ATCGatewayDaemon = ATCGatewayConfig['daemons'][string];

// one daemon as the probe and its alert see it: its name in the registry and its host:port
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

// the one backup image, atcGateway.backupImage, and the credential that pulls it
export interface BackupImage {
  readonly reference: string;
  readonly pullCredential: GHCRPullCredential;
}

export interface ATCGatewayInputs {
  readonly config: ATCGatewayConfig;
  readonly secrets: {
    // pulls the gateway's and the backup's images, which are private
    readonly pullCredential: GHCRPullCredential;

    // the bearer token the gateway presents to each daemon, by daemon name
    readonly tokens: Readonly<Record<string, Output<string>>>;

    // restic to R2; without it there is no backup CronJob
    readonly backup?: ATCGatewayBackupSecrets;

    // the one address the Access policy in front of the gateway's sign-in pages lets in
    readonly ownerEmail: Output<string>;
  };
}

// the stack config's nixie object; setting it approves the deploy
export interface NixieConfig {
  // the nixie and nixie-web images of one release, each by tag and digest
  readonly image: string;
  readonly webImage: string;

  // the one public DNS name, which points at the host's tailnet address
  readonly hostname: string;
}

// a nightly restic backup of nixie.db and keys.db to nixie's own R2 bucket
export interface NixieBackupInputs {
  readonly image: string;
  readonly pullCredential: GHCRPullCredential;
  readonly secrets: {
    readonly repository: Output<string>;
    readonly password: Output<string>;
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

// the stack config's files object; setting it approves the deploy
export interface FilesConfig {
  // the files service's image, by tag and digest
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

  // pulls the files image and the backup image, which are private
  readonly pullCredential: GHCRPullCredential;

  // the SHA-256 of each role token, as hex; the cluster never holds a token
  readonly tokenHashes: {
    readonly agent: Output<string>;
    readonly owner: Output<string>;
  };

  // without it there is no backup CronJob
  readonly backup?: FilesBackupInputs;
}
