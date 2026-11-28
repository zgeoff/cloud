# Reads the Caddyfile that geoffcloud's own config gives the TLS front (modules/public-front.nix)
# and checks it whole, then has the front's own Caddy build, which holds the rate limit handler,
# validate it. public-front-vm boots the front with Caddy's local CA instead, so this check is the
# one that covers the host's ACME issuer. Each case runs on its own, in a fresh directory, as a bats test.
# Run: bun run test:nixos public-front
{
  nixpkgs,
  imp,
  geoffcloud,
}:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = nixpkgs.lib;
  testUtilsCheck = import ./test-utils-check.nix { inherit pkgs imp; };
  renderCases = import ./test-utils/render-cases.nix { inherit lib; };
  caddy = geoffcloud.config.services.caddy;

  cases = [
    {
      title = "it writes the Caddyfile of geoffcloud: the impd-mcp paths to the loopback listener of impd, a 404 for any other, and a certificate by TLS-ALPN-01 alone";
      script = ''
        diff -u - ${caddy.configFile} <<'EOF'
        {
        	admin off
        	auto_https disable_redirects
        	servers {
        		protocols h1 h2
        	}

        	log {
        		level ERROR
        	}
        }

        impz.geoff.cloud {
        	tls {
        		issuer acme {
        			disable_http_challenge
        		}
        	}

        	@route `{path} in ["/mcp","/.well-known/oauth-authorization-server","/.well-known/oauth-protected-resource","/.well-known/oauth-protected-resource/mcp","/oauth2/authorize","/oauth2/token","/oauth2/revoke","/login","/enroll","/consent","/error"]`
        	handle @route {
        		rate_limit {
        			zone by_address {
        				key {remote_host}
        				events 120
        				window 1m
        				ipv6_prefix 64
        			}
        		}
        		reverse_proxy 127.0.0.1:7071 {
        			flush_interval -1
        		}
        	}
        	handle {
        		respond 404
        	}
        }
        EOF
      '';
    }
    {
      title = "it has the Caddy build of the front validate the Caddyfile of geoffcloud";
      script = ''
        mkdir home
        status=0
        env -i HOME="$PWD/home" XDG_DATA_HOME="$PWD/home/data" XDG_CONFIG_HOME="$PWD/home/config" \
          ${lib.getExe caddy.package} validate --adapter caddyfile --config ${caddy.configFile} > out 2> err || status=$?

        assert_equal "$status" 0
        # the output of caddy validate
        assert_equal "$(cat out)" "Valid configuration"
      '';
    }
  ];
in
pkgs.runCommand "public-front-check"
  {
    nativeBuildInputs = [
      (pkgs.bats.withLibraries (p: [
        p.bats-support
        p.bats-assert
      ]))
      pkgs.diffutils
    ];
    # the shared test utilities pass their own tests before any case relies on them
    inherit testUtilsCheck;
  }
  ''
    bats --timing --print-output-on-failure ${pkgs.writeText "public-front.bats" (renderCases cases)}
    touch $out
  ''
