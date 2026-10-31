#!/bin/sh
# Fetches Wube's published game data (prototypes only, no graphics) for the tests.
set -e
cd "$(dirname "$0")"
if [ -d .factorio-data/.git ]; then
  git -C .factorio-data pull --ff-only
else
  git clone --depth 1 https://github.com/wube/factorio-data .factorio-data
fi
