#!/bin/sh
set -eu

output=$1
source_dir=${2:-.}
version=${SCROLLOVERVIEW_BUILD_VERSION:-}

if [ -z "$version" ] && git -C "$source_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    version=$(git -C "$source_dir" rev-parse --short=12 HEAD)

    if [ -n "$(git -C "$source_dir" status --porcelain --untracked-files=normal)" ]; then
        version="${version}-dirty"
    fi
fi

if [ -z "$version" ]; then
    version=unknown
fi

mkdir -p "$(dirname "$output")"
temporary="${output}.tmp"

printf '#pragma once\n#define SCROLLOVERVIEW_VERSION "%s"\n' "$version" >"$temporary"

if [ -f "$output" ] && cmp -s "$temporary" "$output"; then
    rm -f "$temporary"
else
    mv "$temporary" "$output"
fi
