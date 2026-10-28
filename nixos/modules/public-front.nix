# The host's TLS front: Caddy on 443 for each public route the exposure registry lists with kind
# front-route. Each route serves its hostname and proxies only its listed paths to its upstream on
# the host; every other path gets a 404 from the front and never reaches the upstream. A path
# matches only as the request sends it, exactly, so a case change or a dot segment that would
# clean to a listed path still gets the 404.
#
# The certificate comes from Let's Encrypt by TLS-ALPN-01 on 443 itself, so the front opens no
# port 80 and holds no DNS credential. HTTP/3 stays off, so nothing listens on UDP 443. The proxy
# keeps the request's Host and Authorization, flushes each write at once, and sets no timeout, so
# an MCP event stream passes unbuffered for as long as it lasts. The admin API stays off, so a
# config change restarts Caddy rather than reloading it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.public-front;

  # the rate limit handler, which Caddy's own build lacks
  caddy = pkgs.caddy.withPlugins {
    plugins = [ "github.com/mholt/caddy-ratelimit@v0.1.1-0.20260612195517-5625512f24f6" ];
    hash = "sha256-qNJMAahc69hP6VkP0xiuqOGhMYnl7aCZSW9N8QCl2aQ=";
  };

  renderIssuer =
    issuer:
    if issuer == "acme" then
      ''
        tls {
          issuer acme {
            disable_http_challenge
          }
        }
      ''
    else
      "tls internal";

  renderRoute = route: {
    name = route.hostname;
    # no access log: Caddy logs response headers, and a sign-in's redirect carries its code
    value.logFormat = null;
    value.extraConfig = ''
      ${renderIssuer cfg.issuer}
      @route `{path} in ${builtins.toJSON route.paths}`
      handle @route {
        rate_limit {
          zone by_address {
            key {remote_host}
            events ${toString cfg.rateLimit.events}
            window ${cfg.rateLimit.window}
            ipv6_prefix 64
          }
        }
        reverse_proxy ${route.upstream} {
          flush_interval -1
        }
      }
      handle {
        respond 404
      }
    '';
  };
in
{
  options.services.public-front = {
    enable = lib.mkEnableOption "the host's TLS front for its public routes";

    routes = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            hostname = lib.mkOption {
              type = lib.types.str;
              example = "mcp.example.com";
              description = "The public name the route serves.";
            };
            upstream = lib.mkOption {
              type = lib.types.str;
              example = "127.0.0.1:7071";
              description = "The plain-HTTP address on the host that the route proxies to.";
            };
            paths = lib.mkOption {
              type = lib.types.nonEmptyListOf lib.types.str;
              example = [ "/mcp" ];
              description = "The exact request paths the route proxies; every other path gets a 404.";
            };
          };
        }
      );
      description = "The public routes the front serves, one per hostname.";
    };

    rateLimit = {
      events = lib.mkOption {
        type = lib.types.ints.positive;
        example = 120;
        description = "The requests one client address, or one IPv6 /64, may send to a route in each window.";
      };
      window = lib.mkOption {
        type = lib.types.str;
        example = "1m";
        description = "The sliding window of the rate limit, as a Caddy duration.";
      };
    };

    issuer = lib.mkOption {
      type = lib.types.enum [
        "acme"
        "internal"
      ];
      default = "acme";
      description = ''
        Where the certificates come from: Let's Encrypt by TLS-ALPN-01, or Caddy's own local CA
        for a test that reaches no ACME server.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.caddy = {
      enable = true;
      package = caddy;
      enableReload = false;
      globalConfig = ''
        admin off
        auto_https disable_redirects
        servers {
          protocols h1 h2
        }
      '';
      virtualHosts = builtins.listToAttrs (map renderRoute cfg.routes);
    };
  };
}
