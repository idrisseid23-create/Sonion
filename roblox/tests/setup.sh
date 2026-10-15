#!/usr/bin/env bash
# Builds the small Luau runner and the Roblox API list the tests use.
# Needs: curl, tar, g++, python3, npm. Run from this folder: ./setup.sh
set -euo pipefail
cd "$(dirname "$0")"

LUAU_CRATE_VERSION="0.22.0+luau740"
if [ ! -x luaurun ]; then
  mkdir -p .build && cd .build
  if [ ! -d "luau0-src-$LUAU_CRATE_VERSION" ]; then
    # The luau0-src crate on crates.io carries the official Luau source code.
    curl -sSL -o luau.crate "https://static.crates.io/crates/luau0-src/luau0-src-$LUAU_CRATE_VERSION.crate"
    tar xzf luau.crate
  fi
  L="luau0-src-$LUAU_CRATE_VERSION/luau"
  INC="-I$L/Common/include -I$L/Ast/include -I$L/Compiler/include -I$L/VM/include -I$L/VM/src -I$L/Bytecode/include -I$L/Compiler/src"
  for f in $L/Ast/src/*.cpp $L/Compiler/src/*.cpp $L/VM/src/*.cpp $L/Common/src/*.cpp $L/Bytecode/src/*.cpp; do
    [ -f "$f" ] || continue
    out="obj_$(basename "$(dirname "$(dirname "$f")")")_$(basename "$f" .cpp).o"
    [ -f "$out" ] || g++ -std=c++17 -O2 -c "$f" $INC -o "$out" &
  done
  wait
  g++ -std=c++17 -O2 ../runner.cpp $INC obj_*.o -o ../luaurun
  cd ..
fi

if [ ! -f api.luau ]; then
  mkdir -p .build/rbxts && cd .build/rbxts
  npm pack @rbxts/types --silent > /dev/null
  tar xzf rbxts-types-*.tgz
  cd ../..
  python3 gen_api.py .build/rbxts/package/include/generated
fi
echo "Ready. Run: ./luaurun physics_test.luau && ./luaurun api_test.luau"
