# shellcheck shell=bash
# create_stub_apt_suite <archive> <suite> [<package>=<version>[/<depends>]]...: writes one suite of
# an unsigned apt archive under <archive>, the directory that a deb822 source's URIs line names, for
# start_stub_apt_archive to serve. Each package is an empty `Architecture: all` .deb in
# <archive>/pool/main, which <depends>, when given, makes depend on another package by name. The
# suite gets the four components that Ubuntu's sources name, main with the packages and the others
# empty, each with a Packages index, and a Release that lists every index with its SHA256, and
# no InRelease or Release.gpg, so apt reads it only when the case allows an unsigned repository.
#
# The .deb of a package and version is the same file byte for byte on each call, in any archive, so
# two archives can serve one version as the Ubuntu archive and its snapshot do. It needs dpkg-deb.
create_stub_apt_suite() {
  local archive="$1" suite="$2" spec name version depends work deb component index
  shift 2
  mkdir -p "$archive/pool/main" "$archive/dists/$suite"
  work="$(mktemp -d)"
  for component in main universe restricted multiverse; do
    mkdir -p "$archive/dists/$suite/$component/binary-amd64"
    : > "$archive/dists/$suite/$component/binary-amd64/Packages"
  done
  for spec in "$@"; do
    name="${spec%%=*}" version="${spec#*=}" depends=""
    if [[ "$version" == */* ]]; then
      depends="${version#*/}" version="${version%%/*}"
    fi
    deb="pool/main/${name}_${version}_all.deb"
    rm -rf "$work/pkg"
    mkdir -p "$work/pkg/DEBIAN"
    {
      echo "Package: $name"
      echo "Version: $version"
      echo "Architecture: all"
      echo "Maintainer: stub <stub@example.invalid>"
      if [ -n "$depends" ]; then echo "Depends: $depends"; fi
      echo "Description: stub package"
    } > "$work/pkg/DEBIAN/control"
    find "$work/pkg" -exec touch -h -d @0 {} +
    SOURCE_DATE_EPOCH=0 dpkg-deb --root-owner-group -Zgzip --build "$work/pkg" \
      "$archive/$deb" > /dev/null
    {
      cat "$work/pkg/DEBIAN/control"
      echo "Filename: $deb"
      echo "Size: $(stat -c %s "$archive/$deb")"
      echo "SHA256: $(sha256sum "$archive/$deb" | cut -d' ' -f1)"
      echo
    } >> "$archive/dists/$suite/main/binary-amd64/Packages"
  done
  rm -rf "$work"
  {
    echo "Origin: Ubuntu"
    echo "Suite: $suite"
    echo "Codename: noble"
    echo "Date: Thu, 01 Jan 2026 00:00:00 UTC"
    echo "Architectures: amd64"
    echo "Components: main universe restricted multiverse"
    echo "SHA256:"
    for component in main universe restricted multiverse; do
      index="$component/binary-amd64/Packages"
      printf ' %s %s %s\n' "$(sha256sum "$archive/dists/$suite/$index" | cut -d' ' -f1)" \
        "$(stat -c %s "$archive/dists/$suite/$index")" "$index"
    done
  } > "$archive/dists/$suite/Release"
}
