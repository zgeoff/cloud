import { pinnedImagePattern } from './pinned-image-pattern.ts';

// Throws unless the stack config value at key, such as "nixie.image", names an image by tag and
// digest, so a deploy never pulls a tag that can move.
export function requirePinnedImage(
  key: string,
  image: string | undefined,
): asserts image is string {
  if (image === undefined || !pinnedImagePattern.test(image)) {
    throw new Error(`stack config "${key}" must name an image by tag and digest`);
  }
}
