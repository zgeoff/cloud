# atc's release binary for the host's atc daemon. The atc daemon pin lives here; the gateway
# images pin their own release in deploy/atc-gateway/versions.env. The two may differ while
# the daemon protocol stays the same: the daemon runs 2.26.2 for its listener log (atc #255)
# and for an imp spawn's workspace on the session host (atc #262), and the gateway stays on
# 2.24.0.
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
  version = "2.26.2";
  # the release's SHA256SUMS line for atc-linux-x64
  sha256 = "4d92b125a68edbd067ea0eaac493790402baa9102229df2843dea962250602e7";
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
