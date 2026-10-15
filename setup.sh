#!/usr/bin/env bash
# Installs the two dependencies of the Hookit Plugin SDK into ./lib:
#   - inside the Hookit monorepo (sdk/plugin-sdk): symlinks to the monorepo's lib/v4-core and lib/forge-std;
#   - anywhere else (the folder copied out on its own): pinned clones of Uniswap v4-core v4.0.0 and forge-std v1.16.2.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p lib

MONO="../../lib"
link_or_clone() { # name, monorepo dir, git url, tag, probe file
  local name="$1" mono="$2" url="$3" tag="$4" probe="$5"
  if [ -e "lib/$name/$probe" ]; then echo "lib/$name: present"; return; fi
  rm -rf "lib/$name"
  if [ -e "$MONO/$mono/$probe" ]; then
    ln -s "../$MONO/$mono" "lib/$name"
    echo "lib/$name -> monorepo $MONO/$mono"
  else
    git clone --quiet --depth 1 --branch "$tag" "$url" "lib/$name"
    echo "lib/$name: cloned $url@$tag"
  fi
}

link_or_clone v4-core v4-core https://github.com/Uniswap/v4-core v4.0.0 src/types/PoolKey.sol
link_or_clone forge-std forge-std https://github.com/foundry-rs/forge-std v1.16.2 src/Test.sol
echo "ok: run 'forge build && forge test'"
