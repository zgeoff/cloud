import type { Config, Output } from '@pulumi/pulumi';
import type { z } from 'zod';
import type { atcGatewayConfigSchema } from './atc-gateway-config-schema.ts';

// the process environment as index.ts reads it once: .env's values, resolved by `op run`
export type Environment = Readonly<Record<string, string | undefined>>;

// the stack config methods the inputs group reads: Pulumi's Config, or a stand-in in a test
export type StackConfig = Pick<Config, 'get' | 'getBoolean' | 'getObject'>;

// the atcGateway stack config as written, before the schema fills in each default
export type ATCGatewayRawConfig = z.input<typeof atcGatewayConfigSchema>;

// the atcGateway stack config once the schema has checked it
export type ATCGatewayConfig = z.output<typeof atcGatewayConfigSchema>;

// one daemon the gateway dials, checked
export type ATCGatewayDaemon = ATCGatewayConfig['daemons'][string];

export type ATCDaemonAlertSeverity = ATCGatewayDaemon['alertSeverity'];

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

export interface ATCGatewayInputs {
  readonly config: ATCGatewayConfig;
  readonly secrets: {
    // the bearer token the gateway presents to each daemon, by daemon name
    readonly tokens: Readonly<Record<string, Output<string>>>;

    // restic to R2; without it there is no backup CronJob
    readonly backup?: ATCGatewayBackupSecrets;
  };
}
