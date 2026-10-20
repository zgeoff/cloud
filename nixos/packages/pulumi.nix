# The Pulumi CLI release for the host's scheduled drift check (modules/drift-check.nix), with its
# language hosts: the check's project names the Bun runtime, whose host it starts. The pin is the
# release that infra's @pulumi/pulumi pins at the time of writing; a refresh that runs no program
# reads the state with any later release, so the two move apart without breaking the check. The
# binaries are static, so they run as the release ships them.
{
  lib,
  stdenvNoCC,
  fetchurl,
}:
let
  version = "3.268.0";
  # the release's pulumi-<version>-checksums.txt line for the linux-x64 tarball
  sha256 = "903cafeaa9f6327e4bf53a8b7b99ae660f26198acfa804a2f982bf5de3f1de0b";
in
stdenvNoCC.mkDerivation {
  pname = "pulumi";
  inherit version;

  src = fetchurl {
    url = "https://get.pulumi.com/releases/sdk/pulumi-v${version}-linux-x64.tar.gz";
    inherit sha256;
  };

  dontStrip = true;
  dontPatchELF = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 -t $out/bin pulumi pulumi-language-bun
    runHook postInstall
  '';

  meta = {
    description = "Pulumi CLI";
    homepage = "https://github.com/pulumi/pulumi";
    license = lib.licenses.asl20;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "pulumi";
    platforms = [ "x86_64-linux" ];
  };
}
