//go:build darwin

// SPDX-License-Identifier: Apache-2.0

package macos

// The mount directory may exist before cidata's guest agent becomes executable.
// Wait at most 60 one-second intervals, then fail without inventing boot-done.
// Related: Claude-Cage #315 and the independent 30s proposal in #362/d1ba447.
const initScript = `#!/bin/sh
set -eux
date
agent=/Volumes/cidata/lima-guestagent
waited=0
while [ ! -f "$agent" ] || [ ! -x "$agent" ]; do
  if [ "$waited" -ge 60 ]; then
    echo "cidata guest agent did not become executable within 60s" >&2
    exit 1
  fi
  waited=$((waited + 1))
  sleep 1
done
exec "$agent" fake-cloud-init
`
