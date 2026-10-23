# Secure Boot on geoffcloud

geoffcloud boots through [lanzaboote](https://github.com/nix-community/lanzaboote), which installs
systemd-boot and signs it, the fallback loader and one unified kernel image per generation with the
host's own Secure Boot keys. The firmware checks those signatures only once the keys are enrolled in
it and Secure Boot is on for the VM in the Onidel panel. Until then, the host boots the same signed
files without the check.

The key bundle sits on `vda` at `/var/lib/sbctl`, readable by root only, and the 1Password item
`secure-boot-keys` holds a copy of it for a reinstall. lanzaboote signs the boot files at every
switch with the bundle's db key, and it refuses to install an unsigned file. So a switch to the
lanzaboote config fails at the boot loader install while the bundle is missing, and the host keeps
booting its previous system.

## Turn Secure Boot on

The steps run in a host window that the owner approved, because the reboots stop k3s, imp-host and
every imp. Each step names what to do when it fails. A failure before step 7 leaves the firmware's
check off, so the host boots as it did before.

Before you start:

- Take an Onidel snapshot of `vda`:
  `op run --env-file=.env -- bun run onidel:snapshot pre-secure-boot`.
- Keep the Onidel noVNC console at hand. It shows the systemd-boot menu and the firmware's messages,
  which SSH cannot.
- Check that Secure Boot is off: `bun run ops:host -- 'bootctl status'` prints
  `Secure Boot: disabled` or `Secure Boot: disabled (setup)`.

1. Create the keys on the host:

   ```bash
   bun run ops:host -- 'nix run github:NixOS/nixpkgs/nixos-26.05#sbctl -- create-keys'
   ```

   Expect `Secure boot keys created!`. sbctl writes the bundle to `/var/lib/sbctl`, with the private
   keys readable by root only.

   **If it fails:** nothing on the boot path changed. Remove the partial bundle with
   `bun run ops:host -- 'rm -rf /var/lib/sbctl'`, then run the step again.

2. Store a copy of the bundle in 1Password. The archive travels on SSH's stdout, never on a command
   line:

   ```bash
   bun run --silent ops:host -- 'tar -C /var/lib -czf - sbctl' |
     op document create - --vault cloud --title secure-boot-keys --file-name sbctl.tar.gz
   op document get secure-boot-keys --vault cloud | tar -tzf - | grep 'keys/db/db.key'
   ```

   Expect `sbctl/keys/db/db.key`. Without it, delete the item and store the copy again: a reinstall
   stages the bundle from this item.

3. Switch the host to the lanzaboote config from a clean checkout of `main`, as
   [Switch the host](./workflows.md#switch-the-host) describes:

   ```bash
   bun run ops:switch-host
   ```

   Expect the script to finish without an error. lanzaboote signs an entry for each generation that
   the system profile holds, so an older generation stays bootable from the menu.

   **If the switch fails at the boot loader install:** the ESP keeps the previous systemd-boot
   entries, so the host still boots the previous system. Check that `/var/lib/sbctl/keys/db/db.key`
   exists on the host, fix what the error names, and run the switch again.

4. Check the signed boot files:

   ```bash
   bun run ops:host -- 'sbctl verify'
   ```

   Expect `is signed` on `EFI/BOOT/BOOTX64.EFI`, `EFI/systemd/systemd-bootx64.efi` and each
   `EFI/Linux/nixos-generation-*.efi`. The kernels and initrds under `EFI/nixos/` show as not
   signed, which is expected: each signed image checks their hashes instead.

   **If a loader or an image under `EFI/Linux` is not signed:** stop. Reinstall the boot files with
   `bun run ops:host -- '/run/current-system/bin/switch-to-configuration boot'`, then check again.

5. Reboot the host with Secure Boot still off, so the first boot through lanzaboote's files happens
   while the firmware does not check them. Then check that it booted the switched system:

   ```bash
   bun run ops:host -- 'systemctl reboot'
   ```

   Wait until `tailscale ping geoffcloud` answers, then check:

   ```bash
   bun run ops:host -- 'test "$(readlink -f /run/booted-system)" = "$(readlink -f /run/current-system)" && echo same'
   ```

   Expect `same`.

   **If the host does not come back:** in the noVNC console, pick an older generation in the
   systemd-boot menu. Then follow
   [The system cannot boot any generation anymore](https://github.com/nix-community/lanzaboote/blob/v1.2.0/docs/explanation/troubleshooting.md#the-system-cannot-boot-any-generation-anymore)
   from lanzaboote's troubleshooting guide if no generation boots, with the installer that
   [If kexec still fails](./reinstall-geoffcloud.md#if-kexec-still-fails) boots.

6. Enroll the keys. The firmware accepts new keys only in Setup Mode, so check that first:

   ```bash
   bun run ops:host -- 'bootctl status' | grep 'Secure Boot'
   ```

   Expect `Secure Boot: disabled (setup)`. Then enroll the keys, with Microsoft's keys beside them,
   so firmware drivers signed by Microsoft still load:

   ```bash
   bun run ops:host -- 'sbctl enroll-keys --microsoft'
   ```

   Expect `Enrolled keys to the EFI variables!`.

   **If `bootctl` prints `Secure Boot: disabled` without `(setup)`:** the firmware holds a Platform
   Key, and sbctl cannot enroll over it. Stop, and ask the owner to reset the VM's Secure Boot keys
   to Setup Mode. Never clear the firmware's forbidden-signature database (dbx) to get there.

   **If the enrollment fails:** the firmware stays in Setup Mode and checks nothing. Fix what the
   error names and enroll again.

   **CAUTION:** The next step is the first boot at which the firmware checks the boot files. A file
   that fails the check stops the boot before Linux starts, and SSH and the tailnet stay down. Keep
   the noVNC console open, and have the owner ready to turn Secure Boot off again in the panel.

7. Ask the owner to turn Secure Boot on for the VM in the Onidel panel and to reboot the VM.

   **If the host does not boot:** have the owner turn Secure Boot off in the panel and reboot. The
   host then boots the same files without the check. Find the file that failed with `sbctl verify`
   and `sbctl status`, fix it with steps 4 and 6, and run this step again.

8. Check that the firmware enforces Secure Boot with the host's keys:

   ```bash
   bun run ops:host -- 'bootctl status' | grep 'Secure Boot'
   ```

   Expect `Secure Boot: enabled (user)`.

## Switches and reinstalls

Each later switch signs the new generation with the bundle on `vda`, so a switch needs no extra
step. A reinstall needs Secure Boot off, because kernel lockdown blocks the kexec that
`nixos-anywhere` uses, and it stages the bundle from `secure-boot-keys`
([the reinstall runbook](./reinstall-geoffcloud.md)). After a reinstall, turn Secure Boot on again
from step 6: its `bootctl` check shows whether the firmware kept the enrolled keys. With
`Secure Boot: disabled (setup)`, enroll them again. With `Secure Boot: disabled`, go on to step 7.
