# impd's service clients: the clients that sign in on impd's public MCP route with a secret and no
# person present, such as a verify run's read-only client. impd reads two files at start, named by
# its settings IMP_MCP_SERVICE_TOKEN_FILE and IMP_MCP_SERVICE_CLIENTS_FILE: the token file holds each
# client's scopes and the sha256 digests of its secrets, and the clients file holds the imps each
# client may reach. The module writes both under /etc/imp, which imp-host mounts read-only, and sets
# both settings. impd refuses a token file whose resource is not its public MCP origin and /mcp, so
# the module derives the resource from services.imp.settings.IMP_MCP_PUBLIC_URL.
#
# Each file is a copy, not a link into the store, because a link would dangle inside imp-host,
# which mounts /etc/imp and not the store. impd refuses to start on a file its parser refuses, so
# the assertions refuse each such client list at evaluation, with the same rules: at least one
# client, a public MCP origin of https and a host alone, a name of [a-z][a-z0-9-]{0,31}, at least one scope impd knows, 1 or 2 digests of 64
# lowercase hex characters, no digest shared by two clients, and 1 to 32 imp patterns. impd reads
# the files only at start, so a change to either restarts imp-host.
{ config, lib, ... }:
let
  cfg = config.services.impd-service-clients;
  publicURL = config.services.imp.settings.IMP_MCP_PUBLIC_URL or null;
  isOrigin = builtins.isString publicURL && builtins.match "https://[^/]+" publicURL != null;
  knownScopes = [
    "read"
    "exec"
    "manage"
  ];
  digestsOf = lib.concatMap (client: client.secretDigests) (lib.attrValues cfg.clients);
  sharedDigests = lib.unique (
    lib.filter (digest: lib.count (other: other == digest) digestsOf > 1) digestsOf
  );
  tokenText = builtins.toJSON {
    resource = if isOrigin then "${publicURL}/mcp" else null;
    clients = lib.mapAttrs (_: client: { inherit (client) scopes secretDigests; }) cfg.clients;
  };
  clientsText = builtins.toJSON {
    clients = lib.mapAttrs (_: client: { inherit (client) imps; }) cfg.clients;
  };
  clientAssertions =
    name: client:
    let
      badScopes = lib.filter (scope: !(lib.elem scope knownScopes)) client.scopes;
      badDigests = lib.filter (digest: builtins.match "[0-9a-f]{64}" digest == null) client.secretDigests;
      badImps = lib.filter (
        pattern: builtins.match "\\*|[a-z][a-z0-9-]{0,30}|[a-z][a-z0-9-]{0,29}\\*" pattern == null
      ) client.imps;
      digestCount = lib.length client.secretDigests;
      impCount = lib.length client.imps;
    in
    [
      {
        assertion = builtins.match "[a-z][a-z0-9-]{0,31}" name != null;
        message = "impd service client ${name}: a name must match [a-z][a-z0-9-]{0,31}";
      }
      {
        assertion = client.scopes != [ ] && badScopes == [ ];
        message = "impd service client ${name}: scopes must be one or more of read, exec and manage";
      }
      {
        assertion = digestCount >= 1 && digestCount <= 2 && badDigests == [ ];
        message = "impd service client ${name}: secretDigests must hold 1 or 2 digests of 64 lowercase hex characters";
      }
      {
        assertion = impCount >= 1 && impCount <= 32 && badImps == [ ];
        message = "impd service client ${name}: imps must hold 1 to 32 patterns, each *, an imp name, or a name prefix and a trailing *";
      }
    ];
in
{
  options.services.impd-service-clients = {
    enable = lib.mkEnableOption "impd's service clients on its public MCP route";

    clients = lib.mkOption {
      default = { };
      description = "The service clients, by name.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            scopes = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              example = [ "read" ];
              description = "The scopes impd gives the client.";
            };

            secretDigests = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "The sha256 digests, in lowercase hex, of the client's secrets: two during a rotation.";
            };

            imps = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              example = [ "*" ];
              description = "The imps the client may reach: *, an imp name, or a name prefix and a trailing *.";
            };
          };
        }
      );
    };

    tokenFile = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "/etc/imp/service-tokens.json";
      description = "The token file's path, for impd's IMP_MCP_SERVICE_TOKEN_FILE.";
    };

    clientsFile = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "/etc/imp/service-clients.json";
      description = "The clients file's path, for impd's IMP_MCP_SERVICE_CLIENTS_FILE.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.clients != { };
        message = "services.impd-service-clients.clients must name at least one client";
      }
      {
        assertion = isOrigin;
        message = "services.impd-service-clients needs services.imp.settings.IMP_MCP_PUBLIC_URL, an https origin with no path";
      }
      {
        assertion = sharedDigests == [ ];
        message = "impd service clients must not share a secret digest: ${lib.concatStringsSep ", " sharedDigests}";
      }
    ]
    ++ lib.concatLists (lib.mapAttrsToList clientAssertions cfg.clients);

    services.imp.settings.IMP_MCP_SERVICE_TOKEN_FILE = cfg.tokenFile;
    services.imp.settings.IMP_MCP_SERVICE_CLIENTS_FILE = cfg.clientsFile;

    environment.etc."imp/service-tokens.json" = {
      mode = "0444";
      text = tokenText;
    };
    environment.etc."imp/service-clients.json" = {
      mode = "0444";
      text = clientsText;
    };

    systemd.services.imp-host.restartTriggers = [
      tokenText
      clientsText
    ];
  };
}
