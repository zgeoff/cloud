const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

// the length of an upload's id: 22 characters of 62 hold about 131 random bits
export const fileIDLength = 22;

// A new upload's unguessable id, from the system's secure random source. A byte of 248 or more is
// dropped, so each character is equally likely.
export function mintFileID(): string {
  let id = '';

  while (id.length < fileIDLength) {
    for (const byte of crypto.getRandomValues(new Uint8Array(32))) {
      if (byte < 248 && id.length < fileIDLength) {
        id += alphabet.charAt(byte % alphabet.length);
      }
    }
  }

  return id;
}
