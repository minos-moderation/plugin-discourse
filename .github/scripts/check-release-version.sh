#!/usr/bin/env bash
# Proves, before .github/workflows/release.yml publishes a release, that the version
# plugin.rb declares equals the tag and that the licence is in the tree. Discourse installs
# the plugin from its git URL, so there is no archive to check: the tagged tree IS the
# release. Every failed property is reported before the script exits 1.
#
#   .github/scripts/check-release-version.sh <tag>      (from the repository's root)
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <tag>" >&2
  exit 2
fi
tag="$1"

failed=0
fail() {
  echo "check-release-version: $*" >&2
  failed=1
}

if ! [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$ ]]; then
  echo "check-release-version: the tag '$tag' is not v<major>.<minor>.<patch>[-<suffix>]" >&2
  exit 1
fi
expected="${tag#v}"

if [ ! -f LICENSE ]; then
  fail "the licence LICENSE is not in the tree"
fi

# The version as Discourse's Plugin::Metadata reads it: the header's comment lines, up to
# the first line that is neither blank nor a comment; "# version: <value>".
version=''
if [ -f plugin.rb ]; then
  version="$(awk '
    /^[[:space:]]*$/ { next }
    !/^[[:space:]]*#/ { exit }
    {
      line = $0
      sub(/^[[:space:]]*#/, "", line)
      split(line, parts, ":")
      name = parts[1]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      if (name == "version") {
        sub(/^[^:]*:/, "", line)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        print line
        exit
      }
    }' plugin.rb)"
fi
if [ -z "$version" ]; then
  fail "no '# version:' in the header of plugin.rb (the tag is $tag)"
elif [ "$version" != "$expected" ]; then
  fail "plugin.rb declares version $version but the tag is $tag (expects $expected)"
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "check-release-version: plugin.rb declares version $version, the tag is $tag, LICENSE is present"
