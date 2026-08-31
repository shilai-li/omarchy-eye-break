#!/usr/bin/env bash

# Unit tests for Model.js. No Qt, no compositor, no shell — the whole point of
# keeping the scheduling math in a plain .js file is that it can be checked
# like this, in under a second, from any terminal.
#
#   bash test/model-test.sh

set -euo pipefail
cd "$(dirname "$0")/.."
exec node test/model-test.js
