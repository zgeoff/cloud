# Reads the Caddyfile that geoffcloud's own config gives the TLS front (modules/public-front.nix)
# and checks it whole, then has the front's own Caddy build, which holds the rate limit handler,
# validate it. public-front-vm boots the front with Caddy's local CA instead, so this check is the
# one that covers the host's ACME issuer. Each case runs on its own, in a fresh directory, under
# test-support/shell/run-cases.sh.
# Run: bun run test:nixos public-front
{
  nixpkgs,
  imp,
  geoffcloud,
}:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = nixpkgs.lib;
  testLib = import ./test-utils/build-shell-lib-source.nix { inherit lib; };
  testUtilsCheck = import ./test-utils-check.nix { inherit pkgs imp; };
  renderCases = import ./test-utils/render-cases.nix { inherit lib; };
  caddy = geoffcloud.config.services.caddy;

  cases = [
    {
      title = "it writes geoffcloud's Caddyfile: the registry's impd-mcp paths to impd's loopback listener, a 404 for any other, and a certificate by TLS-ALPN-01 alone";
      script = ''
        assert_files_equal - ${caddy.configFile} <<'EOF'
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

        mcp.geoff.cloud {
        	tls {
        		issuer acme {
        			disable_http_challenge
        		}
        	}

        	@route `{path} in ["/mcp","/.well-known/oauth-authorization-server","/.well-known/oauth-protected-resource","/.well-known/oauth-protected-resource/mcp","/oauth2/authorize","/oauth2/token","/oauth2/revoke","/login","/consent","/error"]`
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
      title = "it has the front's Caddy build validate geoffcloud's Caddyfile";
      script = ''
        mkdir home
        status=0
        env -i HOME="$PWD/home" XDG_DATA_HOME="$PWD/home/data" XDG_CONFIG_HOME="$PWD/home/config" \
          ${lib.getExe caddy.package} validate --adapter caddyfile --config ${caddy.configFile} > out 2>&1 || status=$?

        assert_equals 0 "$status" "caddy validate's exit status"
        assert_equals 1 "$(grep -c '"msg":"Valid configuration"' out)" "the valid configuration lines"
      '';
    }
  ];
in
pkgs.runCommand "public-front-check"
  {
    nativeBuildInputs = [ pkgs.diffutils ];
    # the shared test utilities pass their own tests before any case relies on them
    inherit testUtilsCheck;
  }
  ''
    source ${testLib}/run-cases.sh
    source ${testLib}/assert-equals.sh
    source ${testLib}/assert-files-equal.sh
    source ${pkgs.writeText "public-front-cases.sh" (renderCases cases)}
    run_cases
    touch $out
  ''
