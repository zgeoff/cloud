# atc's release binary for the host's atc daemon. The atc daemon pin lives here; the gateway
# images pin their own release in deploy/atc-gateway/versions.env, so bump both together.
# The binary is a Bun single-file executable linked against glibc: patch only its interpreter
# and library path. Never strip it, which would drop the .bun section that holds the program.
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:
let
  version = "2.24.0";
  # the release's SHA256SUMS line for atc-linux-x64
  sha256 = "7ad985d1deb0edc614b1ed1466db885e5f5a36af32750633e853b1490319787b";
in
stdenv.mkDerivation {
  pname = "atc";
  inherit version;

  src = fetchurl {
    url = "https://github.com/zgeoff/atc/releases/download/%40zgeoff/atc%40${version}/atc-linux-x64";
    inherit sha256;
  };

  dontUnpack = true;
  dontStrip = true;
  nativeBuildInputs = [ autoPatchelfHook ];

  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/bin/atc
    runHook postInstall
  '';

  meta = {
    description = "atc, the agent session controller";
    homepage = "https://github.com/zgeoff/atc";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "atc";
  };
}
