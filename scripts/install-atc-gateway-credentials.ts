import { checkATCCredentialsPreflight } from './check-atc-credentials-preflight.ts';
import { installATCGatewayToken } from './install-atc-gateway-token.ts';
import { installATCGLMSecret } from './install-atc-glm-secret.ts';
import { installATCImpToken } from './install-atc-imp-token.ts';
import type { ATCCredentialsOptions } from './load-atc-credentials-context.ts';
import { loadATCCredentialsContext } from './load-atc-credentials-context.ts';
import { printATCCredentials } from './print-atc-credentials.ts';
import { runProcess } from './run-process.ts';
import { withExitCode } from './with-exit-code.ts';

export function installATCGatewayCredentials(
  options: Readonly<ATCCredentialsOptions>,
): Promise<number> {
  return withExitCode(options.printErr, async () => {
    const context = await loadATCCredentialsContext(options);
    const preflight = await checkATCCredentialsPreflight(context);

    await installATCGLMSecret(context, preflight);
    await installATCGatewayToken(context, preflight);
    await installATCImpToken(context, preflight);
    await printATCCredentials(context);

    return 0;
  });
}

if (import.meta.main) {
  process.exitCode = await installATCGatewayCredentials({
    run: runProcess,
    env: process.env,
    printOut: (text) => {
      process.stdout.write(text);
    },
    printErr: (text) => {
      process.stderr.write(text);
    },
  });
}
