import { generateKeyPairSync } from 'node:crypto';

// the stand-in App: GitHub keeps the public half and the service holds the private one. GitHub
// makes an App's key as 2048-bit RSA (docs.github.com/en/apps: managing-private-keys-for-github-apps)
const keyPair = generateKeyPairSync('rsa', { modulusLength: 2048 });

export const stubApp = { clientID: 'Iv23liStubPreviewApp', privateKey: keyPair.privateKey };
export const stubAppPublicKey = keyPair.publicKey;

// GitHub hands out an App's key as PKCS#1 PEM
export const stubAppKeyPEM = keyPair.privateKey.export({ type: 'pkcs1', format: 'pem' }).toString();
export const stubAppSlug = 'acme-previews';

// GitHub names an App's bot user after the App's slug
export const stubAppLogin = `${stubAppSlug}[bot]`;

// the stand-in App's installations, by ID, each on one account
export const stubInstallations = new Map([
  [7001, 'acme'],
  [7002, 'nursery'],
]);
