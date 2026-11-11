// The images of pepys's stores and backup, from their publishers, by tag and digest. The pepys
// repo's test stack pins the same Garage and s2 images, so the cluster runs what its e2e lane runs.
export const pepysImages = {
  garage:
    'dxflrs/garage:v2.5.0@sha256:677e5b758e4425a325b811c425c026bf35a4bf42f7ddbaa773de3f4fd779a5a5',
  s2: 'ghcr.io/s2-streamstore/s2:0.43.2@sha256:214a7ea92c7bbf5e4b79c57fba642f95765b68eaa143cd11173bcda6d3c4ed09',
  rclone:
    'rclone/rclone:1.71.2@sha256:3103526c506266a9ecdf064efe99bf3677d92ef6407af124d8c56b4f49cbaa51',
} as const;
