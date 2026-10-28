# services.drift-check on a booted VM: the unit's own sandbox starts a provider plugin from its
# state directory and the Node.js language host that the Bun runtime's host runs, and a run whose
# plugin cannot start posts the failed alert. checks/drift-check.nix checks the units and the tree
# in the build sandbox, which never mounts the state directory as systemd does.
#
# No case reaches the internet: the state is a local backend in the store, the random provider's
# plugin sits in the state directory as a download leaves it, and kubectl is
# test-support/shell/create-stub-kubectl.sh, whose store under /run/stub-kube holds the prod lock.
# The check runs the module's tree with one change: its stack file holds the fixture's salt, which
# matches the fixture's passphrase. Discord is test-support/shell/start-stub-discord-webhook.sh on loopback.
# It needs KVM: run `bun run test:nixos drift-check-vm`.
{ nixpkgs }:
let
  pkgs = nixpkgs.legacyPackages.x86_64-linux;
  lib = nixpkgs.lib;
  # the Discord stand-in and the wait it sources, apart from the shared helpers of
  # test-utils/build-shell-lib-source.nix, which every other check reads
  stubDiscord = lib.fileset.toSource {
    root = ../../test-support/shell;
    fileset = lib.fileset.unions [
      ../../test-support/shell/start-stub-discord-webhook.sh
      ../../test-support/shell/wait-for.sh
    ];
  };
  # the kubectl stand-in, with the tools it runs on its PATH, since the unit's PATH has no flock
  stubKubectl =
    let
      source = lib.fileset.toSource {
        root = ../../test-support/shell;
        fileset = ../../test-support/shell/create-stub-kubectl.sh;
      };
    in
    pkgs.runCommand "stub-kubectl" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
      mkdir -p $out/bin $out/libexec
      source ${source}/create-stub-kubectl.sh
      create_stub_kubectl $out/libexec /run/stub-kube /run/stub-kube/calls
      makeWrapper $out/libexec/kubectl $out/bin/kubectl --prefix PATH : ${
        lib.makeBinPath [
          pkgs.bash
          pkgs.coreutils
          pkgs.jq
          pkgs.util-linux
        ]
      }
    '';
  lease = "/run/stub-kube/kube-system/cloud-prod-state.json";
  pulumi = pkgs.callPackage ../packages/pulumi.nix { };
  passphrase = "example-fixture-passphrase";
  invocationRef = "on machine: journalctl -u drift-check.service _SYSTEMD_INVOCATION_ID=";

  # the plugin as `pulumi plugin install` unpacks it, under resource-random-v4.21.2
  randomPlugin = pkgs.runCommand "pulumi-resource-random-4.21.2" {
    src = pkgs.fetchurl {
      url = "https://github.com/pulumi/pulumi-random/releases/download/v4.21.2/pulumi-resource-random-v4.21.2-linux-amd64.tar.gz";
      sha256 = "b980a23ae949bb38fd4bcd2c89cb7686be5814782f5859efddc92ea3dba64673";
    };
  } "mkdir $out && tar -xzf $src -C $out";

  stack = "urn:pulumi:prod::geoff-cloud::pulumi:pulumi:Stack::geoff-cloud-prod";
  provider = "urn:pulumi:prod::geoff-cloud::pulumi:providers:random::default_4_21_2";
  providerId = "0f6e2a4c-8b1d-4e3f-9a5c-7d2b1e0c4f68";
  deployment = pkgs.writeText "deployment.json" (
    builtins.toJSON {
      version = 3;
      deployment.resources = [
        {
          urn = stack;
          custom = false;
          type = "pulumi:pulumi:Stack";
        }
        {
          urn = provider;
          custom = true;
          id = providerId;
          type = "pulumi:providers:random";
          inputs.version = "4.21.2";
          outputs.version = "4.21.2";
          parent = stack;
        }
        {
          urn = "urn:pulumi:prod::geoff-cloud::random:index/randomPet:RandomPet::example";
          custom = true;
          id = "example-pet";
          type = "random:index/randomPet:RandomPet";
          inputs = {
            length = 2;
            separator = "-";
          };
          outputs = {
            id = "example-pet";
            length = 2;
            separator = "-";
          };
          parent = stack;
          provider = "${provider}::${providerId}";
        }
      ];
    }
  );

  # the prod stack of the deployment, in a local backend, and the stack file that stack init wrote
  fixture = pkgs.runCommand "drift-check-vm-state" { nativeBuildInputs = [ pulumi ]; } ''
    export HOME="$TMPDIR/home" PULUMI_HOME="$TMPDIR/home/.pulumi" PULUMI_SKIP_UPDATE_CHECK=true \
      PULUMI_CONFIG_PASSPHRASE=${passphrase} PULUMI_BACKEND_URL="file://$out/backend"
    mkdir -p "$out/backend" "$TMPDIR/project"
    cd "$TMPDIR/project"
    cp ${../../infra/Pulumi.yaml} Pulumi.yaml
    pulumi stack init prod --non-interactive
    pulumi stack import --stack prod --force --file ${deployment}
    cp Pulumi.prod.yaml "$out/Pulumi.prod.yaml"
  '';
in
pkgs.testers.runNixOSTest {
  name = "drift-check-vm";
  nodes.machine =
    { config, ... }:
    let
      tree = pkgs.runCommand "drift-check-vm-tree" { } ''
        cp -a ${config.services.drift-check.tree} $out
        chmod -R u+w $out
        cp ${fixture}/Pulumi.prod.yaml $out/infra/Pulumi.prod.yaml
      '';
    in
    {
      imports = [ ../modules/drift-check.nix ];
      services.drift-check = {
        enable = true;
        credentialsFile = "/etc/drift-check/credentials";
        kubectl = stubKubectl;
        kubeconfig = "/etc/stub-kubeconfig";
      };
      systemd.services.drift-check.serviceConfig.ExecStart =
        lib.mkForce "${pkgs.bash}/bin/bash ${tree}/scripts/run-host-drift-check.sh";
      virtualisation.memorySize = 2048;
    };

  testScript = ''
    import json

    plugins = "/var/lib/private/drift-check/pulumi/plugins"
    plugin = f"{plugins}/resource-random-v4.21.2/pulumi-resource-random"


    def run_check():
        """starts the service and returns its exit status, its invocation id and its journal"""
        machine.execute("systemctl start drift-check.service")
        status = int(machine.succeed("systemctl show -p ExecMainStatus --value drift-check.service"))
        invocation = machine.succeed("systemctl show -p InvocationID --value drift-check.service").strip()
        journal = machine.succeed(f"journalctl -o cat --no-pager _SYSTEMD_INVOCATION_ID={invocation}")
        print(journal)
        return status, invocation, journal


    def script_lines(journal):
        return [line for line in journal.splitlines() if line.startswith(("run-host-drift-check: ", "hold-prod-lock: "))]


    def lease():
        return json.loads(machine.succeed("cat ${lease}"))


    machine.wait_for_unit("multi-user.target")


    with subtest("it boots the VM under KVM, not QEMU's emulation"):
        virt = machine.succeed("systemd-detect-virt").strip()

        assert virt == "kvm", f"the VM runs under {virt!r}: QEMU fell back from KVM"


    with subtest("it starts a binary from a dynamic user's state directory only with ExecPaths on it"):
        # coreutils is one binary that runs the program its name gives, so the copy keeps the name true
        probe = "${pkgs.coreutils}/bin/cp ${pkgs.coreutils}/bin/true \"$STATE_DIRECTORY/true\" && \"$STATE_DIRECTORY/true\""

        status, out = machine.execute(f"systemd-run --wait --pipe --quiet -p DynamicUser=yes -p StateDirectory=noexec-probe ${pkgs.bash}/bin/bash -c '{probe}' 2>&1")
        assert status == 126, f"the probe without ExecPaths exited {status}: {out!r}"
        assert out == "${pkgs.bash}/bin/bash: line 1: /var/lib/noexec-probe/true: Permission denied\n", out

        status, out = machine.execute(f"systemd-run --wait --pipe --quiet -p DynamicUser=yes -p StateDirectory=exec-probe -p ExecPaths=/var/lib/private/exec-probe ${pkgs.bash}/bin/bash -c '{probe}' 2>&1")
        assert (status, out) == (0, ""), f"the probe with ExecPaths exited {status}: {out!r}"


    with subtest("it starts the provider plugin and the Node.js language host, and finds no drift"):
        machine.succeed(
            "systemd-run --unit stub-discord -p Environment=PATH=${pkgs.coreutils}/bin:${pkgs.python3}/bin "
            "${pkgs.bash}/bin/bash -c "
            "'source ${stubDiscord}/start-stub-discord-webhook.sh && start_stub_discord_webhook /run/stub-discord && wait'"
        )
        machine.wait_until_succeeds("test -s /run/stub-discord/port", timeout=30)
        port = machine.succeed("cat /run/stub-discord/port").strip()
        machine.succeed(
            "install -d -m 0700 /etc/drift-check",
            "cat > /etc/drift-check/credentials << EOF\n"
            "PULUMI_BACKEND_URL=file://${fixture}/backend\n"
            "AWS_ACCESS_KEY_ID=example-key-id\n"
            "AWS_SECRET_ACCESS_KEY=example-secret\n"
            "PULUMI_CONFIG_PASSPHRASE=${passphrase}\n"
            "CLOUDFLARE_API_TOKEN=example-cloudflare-token\n"
            "TAILSCALE_OAUTH_CLIENT_ID=example-client-id\n"
            "TAILSCALE_OAUTH_CLIENT_SECRET=example-client-secret\n"
            "TAILSCALE_TAILNET=example.test\n"
            f"ALERT_WEBHOOK_URL=http://127.0.0.1:{port}/api/webhooks/1/example-token\n"
            "EOF",
            "chmod 0600 /etc/drift-check/credentials",
            # as a download leaves it, before systemd first makes the directory the dynamic user's
            "install -d -m 0700 /var/lib/private",
            f"install -d -m 0755 {plugins}",
            f"cp -r --no-preserve=mode ${randomPlugin} {plugins}/resource-random-v4.21.2",
            f"chmod 0755 {plugin}",
        )

        status, invocation, journal = run_check()

        assert status == 0, f"the check exited {status}"
        assert script_lines(journal) == [
            f"hold-prod-lock: took the prod lock as drift-check {invocation}",
            "run-host-drift-check: no drift",
            f"hold-prod-lock: released the prod lock as drift-check {invocation}",
        ], script_lines(journal)
        assert "holderIdentity" not in lease()["spec"], lease()
        assert "    2 unchanged" in journal.splitlines(), "the refresh did not read both resources"
        errors = [line for line in journal.splitlines() if "error" in line]
        assert errors == [], errors
        machine.fail("test -e /run/stub-discord/requests")


    with subtest("it posts the failed alert when the provider plugin cannot start"):
        machine.succeed(f"chmod 0644 {plugin}")

        status, invocation, journal = run_check()

        assert status == 1, f"the check exited {status}"
        assert "fork/exec /var/lib/drift-check/pulumi/plugins/resource-random-v4.21.2/pulumi-resource-random: permission denied" in journal, "the plugin started"
        assert script_lines(journal) == [
            f"hold-prod-lock: took the prod lock as drift-check {invocation}",
            "run-host-drift-check: posted the failed alert",
            f"hold-prod-lock: released the prod lock as drift-check {invocation}",
        ], script_lines(journal)
        assert machine.succeed("cat /run/stub-discord/requests") == "POST /api/webhooks/1/example-token\n"
        body = json.loads(machine.succeed("cat /run/stub-discord/bodies/1.json"))
        assert body == {"content": f"The scheduled drift check failed: ${invocationRef}{invocation}"}, body
        machine.succeed("rm -r /run/stub-discord/requests /run/stub-discord/bodies")


    with subtest("it waits while a Deploy prod run holds the prod lock, then checks and posts no drift alert"):
        machine.succeed(f"chmod 0755 {plugin}")
        # a Deploy prod run's hold that runs out 10 s from now, so the check's first ask finds it held
        machine.succeed(
            "${pkgs.jq}/bin/jq --arg now \"$(date -u -d '-5990 seconds' +%Y-%m-%dT%H:%M:%S.000000Z)\" "
            "'.spec = {holderIdentity: \"deploy-prod 4321\", leaseDurationSeconds: 6000, acquireTime: $now, renewTime: $now}' "
            "${lease} > /run/held.json && mv /run/held.json ${lease}"
        )

        status, invocation, journal = run_check()

        assert status == 0, f"the check exited {status}"
        lines = script_lines(journal)
        assert lines[0].startswith("hold-prod-lock: deploy-prod 4321 holds the prod lock until "), lines
        assert lines[1:] == [
            "hold-prod-lock: deploy-prod 4321 let the prod lock run out at " + lines[0].split(" until ")[1].split(";")[0] + "; taking it over",
            f"hold-prod-lock: took the prod lock as drift-check {invocation}",
            "run-host-drift-check: no drift",
            f"hold-prod-lock: released the prod lock as drift-check {invocation}",
        ], lines
        machine.fail("test -e /run/stub-discord/requests")
  '';
}
