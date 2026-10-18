# Compares the exposure registry's host-port entries (packages/topology/exposure.json) with an
# evaluated NixOS config, both ways, and returns one message per mismatch: [ ] when they agree.
# checks/exposure.nix runs it on geoffcloud's config and tests it.
#
# - A port in networking.firewall's allowedTCPPorts or allowedUDPPorts is open on every
#   interface, the public one included, so it needs a public entry, and a public tcp or udp
#   entry needs its port open there. A tailnet-scope entry's port open there, such as openssh's
#   default 22, is a mismatch.
# - allowPing needs a public icmp entry, and a public icmp entry needs allowPing.
# - A port that networking.firewall.interfaces.<name> opens, or that an inet cloud_host admission
#   narrows, needs a host-scope entry for that interface, and each host-scope entry needs one of
#   them. An entry that marks an admission needs the admission.
# - A path counts as open only when both input chains pass it. An admission only passes its
#   packets on to nixos-fw, so nixos-fw must still accept the port on the admission's interface:
#   the interface is trusted, or nixos-fw opens the port there or on every interface. And
#   inet cloud_host drops a TCP port it admits on every interface that none of the port's
#   admissions names, so nixos-fw opening the port elsewhere opens nothing, and a port open on
#   every interface narrows to its admissions.
# - sshd answers on the trusted tailnet interface whatever the firewall opens, so each of its
#   ports needs a tailnet-scope or public tcp entry while it runs.
# - An interface that carries a default route or a static address is public, so a port opened
#   there needs a public entry, and a host-scope entry never names it.
# - Each of imp's publicPorts publishes a host port past nixos-fw, so it needs a public entry.
# - A port range or extraInputRules cannot be matched with an entry, so either is a mismatch.
{ lib }:
{ config, entries }:
let
  firewall = config.networking.firewall;
  admissions = config.networking.cloudHost.admissions or [ ];
  impPublicPorts = config.services.imp.publicPorts or [ ];
  sshPorts = lib.optionals config.services.openssh.enable config.services.openssh.ports;

  # the interfaces that reach beyond the host: those with a default route or a static address
  publicInterfaces = lib.unique (
    lib.filter (name: name != null) [
      (config.networking.defaultGateway.interface or null)
      (config.networking.defaultGateway6.interface or null)
    ]
    ++ lib.attrNames (
      lib.filterAttrs (
        _: interface: interface.ipv4.addresses != [ ] || interface.ipv6.addresses != [ ]
      ) config.networking.interfaces
    )
  );
  isPublicInterface = name: lib.elem name publicInterfaces;

  hostPorts = lib.filter (entry: entry.kind == "host-port") entries;
  publicEntries = lib.filter (entry: entry.scope == "public") hostPorts;
  hostEntries = lib.filter (entry: entry.scope == "host") hostPorts;

  formatPort = protocol: port: "${protocol} ${toString port}";
  formatEntryPort = entry: formatPort entry.protocol entry.port;
  isPort =
    protocol: port: candidate:
    candidate.protocol == protocol && (candidate.port or null) == port;

  toOpenPorts =
    lists:
    map (port: {
      protocol = "tcp";
      inherit port;
    }) lists.allowedTCPPorts
    ++ map (port: {
      protocol = "udp";
      inherit port;
    }) lists.allowedUDPPorts;
  toRanges =
    lists:
    map (range: range // { protocol = "tcp"; }) lists.allowedTCPPortRanges
    ++ map (range: range // { protocol = "udp"; }) lists.allowedUDPPortRanges;
  formatRange = range: "${range.protocol} ${toString range.from}-${toString range.to}";

  isTCPPortIn =
    lists: port:
    lib.elem port lists.allowedTCPPorts
    || lib.any (range: range.from <= port && port <= range.to) lists.allowedTCPPortRanges;
  # nixos-fw's input chain: a trusted interface (lo always is) passes every port
  isAcceptedByNixosFw =
    interface: port:
    lib.elem interface firewall.trustedInterfaces
    || isTCPPortIn firewall port
    || (firewall.interfaces ? ${interface} && isTCPPortIn firewall.interfaces.${interface} port);
  collectAdmissions = port: lib.filter (admission: admission.port == port) admissions;
  # inet cloud_host's input chain: it drops a TCP port it admits on every interface that no
  # admission of the port names
  isPassedByCloudHost =
    interface: protocol: port:
    let
      portAdmissions = collectAdmissions port;
    in
    protocol != "tcp"
    || portAdmissions == [ ]
    || lib.any (admission: admission.interface == interface) portAdmissions;

  publicPorts = lib.filter (open: open.protocol != "tcp" || collectAdmissions open.port == [ ]) (
    toOpenPorts firewall
  );

  publicPortMismatches = lib.concatMap (
    open:
    let
      entry = lib.findFirst (isPort open.protocol open.port) null hostPorts;
      port = formatPort open.protocol open.port;
    in
    if entry == null then
      [ "${port} is open on every interface with no registry entry" ]
    else if entry.scope != "public" then
      [
        "${port} is open on every interface, but the registry's ${entry.name} entry has scope ${entry.scope}"
      ]
    else
      [ ]
  ) publicPorts;

  stalePublicEntries = lib.concatMap (
    entry:
    if
      entry.protocol == "icmp"
      || lib.any (isPort entry.protocol entry.port) (publicPorts ++ publicInterfacePorts)
    then
      [ ]
    else
      [
        "the registry's ${entry.name} entry is public, but ${formatEntryPort entry} is not open on every interface"
      ]
  ) publicEntries;

  icmpEntry = lib.findFirst (entry: entry.protocol == "icmp") null publicEntries;
  pingMismatches =
    if firewall.allowPing && icmpEntry == null then
      [ "ping is allowed on every interface with no public icmp registry entry" ]
    else if !firewall.allowPing && icmpEntry != null then
      [ "the registry's ${icmpEntry.name} entry is public, but networking.firewall.allowPing is off" ]
    else
      [ ];

  rangeMismatches =
    map (
      range:
      "${formatRange range} is open on every interface as a range, which no registry entry can match"
    ) (toRanges firewall)
    ++ lib.concatLists (
      lib.mapAttrsToList (
        name: lists:
        map (
          range: "${formatRange range} is open on ${name} as a range, which no registry entry can match"
        ) (toRanges lists)
      ) firewall.interfaces
    );

  interfacePorts = lib.concatLists (
    lib.mapAttrsToList (
      name: lists: map (open: open // { interface = name; }) (toOpenPorts lists)
    ) firewall.interfaces
  );
  openInterfacePorts = lib.filter (
    open: isPassedByCloudHost open.interface open.protocol open.port
  ) interfacePorts;
  publicInterfacePorts = lib.filter (open: isPublicInterface open.interface) openInterfacePorts;
  findHostEntry =
    interface: protocol: port:
    lib.findFirst (entry: entry.interface == interface && isPort protocol port entry) null hostEntries;

  publicInterfacePortMismatches = lib.concatMap (
    open:
    if lib.any (isPort open.protocol open.port) publicEntries then
      [ ]
    else
      [
        "${formatPort open.protocol open.port} is open on ${open.interface}, a public interface, with no public registry entry"
      ]
  ) publicInterfacePorts;

  interfacePortMismatches = lib.concatMap (
    open:
    if isPublicInterface open.interface then
      [ ]
    else if findHostEntry open.interface open.protocol open.port == null then
      [
        "${formatPort open.protocol open.port} is open on ${open.interface} with no host-scope registry entry for ${open.interface}"
      ]
    else
      [ ]
  ) openInterfacePorts;

  admissionMismatches = lib.concatMap (
    admission:
    let
      entry = findHostEntry admission.interface "tcp" admission.port;
    in
    if entry == null || !(entry.admission or false) then
      [
        "inet cloud_host admits tcp ${toString admission.port} on ${admission.interface} with no host-scope registry entry that marks the admission"
      ]
    else
      [ ]
  ) admissions;

  publicHostEntries = lib.concatMap (
    entry:
    lib.optional (isPublicInterface entry.interface) "the registry's ${entry.name} entry is host scope on ${entry.interface}, but ${entry.interface} is a public interface"
  ) hostEntries;

  staleHostEntries = lib.concatMap (
    entry:
    let
      isEntryPath =
        candidate: candidate.interface == entry.interface && isPort entry.protocol entry.port candidate;
      opened = lib.any isEntryPath openInterfacePorts;
      dropped = lib.any isEntryPath interfacePorts;
      admitted = lib.any (admission: isEntryPath (admission // { protocol = "tcp"; })) admissions;
      accepted = admitted && isAcceptedByNixosFw entry.interface entry.port;
      port = formatEntryPort entry;
      prefix = "the registry's ${entry.name} entry is host scope on ${entry.interface}";
    in
    lib.optional (!opened && !accepted) (
      if admitted then
        "${prefix}, and inet cloud_host admits ${port} there, but nixos-fw drops it: ${entry.interface} is not trusted, and nixos-fw opens ${port} neither there nor on every interface"
      else if dropped then
        "${prefix}, and nixos-fw opens ${port} there, but inet cloud_host drops it: its admissions for ${port} are on ${
          lib.concatMapStringsSep ", " (admission: admission.interface) (collectAdmissions entry.port)
        }"
      else
        "${prefix}, but nothing opens or admits ${port} there"
    )
    ++
      lib.optional ((entry.admission or false) && !admitted)
        "the registry's ${entry.name} entry marks an admission, but inet cloud_host admits no ${formatEntryPort entry} on ${entry.interface}"
  ) hostEntries;

  # a docker -p spec: [IP:]HOST:CONTAINER, or a bare CONTAINER, with an optional /udp or /tcp suffix
  parsePublishSpec =
    spec:
    let
      halves = lib.splitString "/" spec;
      fields = lib.splitString ":" (lib.head halves);
      # a bare CONTAINER spec publishes on a host port Docker picks, so it has none to read
      hostPort = if lib.length fields >= 2 then lib.elemAt fields (lib.length fields - 2) else "";
    in
    {
      inherit spec;
      protocol = if lib.length halves > 1 then lib.elemAt halves 1 else "tcp";
      port = if builtins.match "[0-9]+" hostPort == null then null else lib.toIntBase10 hostPort;
    };

  impMismatches = lib.concatMap (
    published:
    if published.port == null then
      [ "imp's publicPorts publishes ${published.spec}, whose host port the exposure check cannot read" ]
    else if lib.any (isPort published.protocol published.port) publicEntries then
      [ ]
    else
      [
        "imp's publicPorts publishes ${published.spec} (${formatPort published.protocol published.port}) with no public registry entry"
      ]
  ) (map parsePublishSpec impPublicPorts);

  sshMismatches = lib.concatMap (
    port:
    if
      lib.any (entry: entry.scope == "tailnet" || entry.scope == "public") (
        lib.filter (isPort "tcp" port) hostPorts
      )
    then
      [ ]
    else
      [ "sshd listens on tcp ${toString port} with no tailnet-scope or public registry entry" ]
  ) sshPorts;

  extraRuleMismatches =
    lib.optional (firewall.extraInputRules != "")
      "networking.firewall.extraInputRules is set, and the exposure check cannot read it: open the port through allowedTCPPorts or allowedUDPPorts instead";
in
publicPortMismatches
++ stalePublicEntries
++ pingMismatches
++ rangeMismatches
++ publicInterfacePortMismatches
++ interfacePortMismatches
++ publicHostEntries
++ admissionMismatches
++ staleHostEntries
++ sshMismatches
++ impMismatches
++ extraRuleMismatches
