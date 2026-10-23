# atc's release binary for the host's atc daemon. The atc daemon pin lives here; the gateway
# images pin their own release in images/atc-gateway/versions.env. The two may differ within
# one atc major release, since atc breaks the daemon protocol only in a major release, and
# scripts/switch-geoffcloud.sh refuses a pin of another major than the running gateway. The
# geoffcloud target's image (hosts/geoffcloud/configuration.nix) ships an atc at its guestATC,
# which hooks run only while it prints this release's version; after a bump here, each new imp
# gets a copy of this binary instead, until the target names an image that ships the release.
# The binary stays byte-identical to the release: an imp target copies the daemon's own
# executable into each Ubuntu guest, so a /nix/store interpreter would break every guest.
# It asks for /lib64/ld-linux-x86-64.so.2, which the atc-daemon module binds into the
# service's namespace. atc-interactive.nix is the patched copy for a shell on the host.
{
  lib,
  stdenvNoCC,
  fetchurl,
}:
let
  version = "7.2.0";
  # the release's SHA256SUMS line for atc-linux-x64
  sha256 = "af0ccae8107ae263000737dbec511226351bfbc5bae6dd0e4af107e469860b95";
in
stdenvNoCC.mkDerivation {
  pname = "atc";
  inherit version;

  src = fetchurl {
    url = "https://github.com/zgeoff/atc/releases/download/%40zgeoff/atc%40${version}/atc-linux-x64";
    inherit sha256;
  };

  dontUnpack = true;
  # a Bun single-file executable: stripping drops the .bun section that holds the program,
  # and patchelf would change the bytes the guests receive
  dontStrip = true;
  dontPatchELF = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/bin/atc
    runHook postInstall
  '';

  # fails the build if any fixup step changed the release's bytes
  postFixup = ''
    echo "${sha256}  $out/bin/atc" | sha256sum -c
  '';

  meta = {
    description = "atc, the agent session controller";
    homepage = "https://github.com/zgeoff/atc";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "atc";
  };
}
