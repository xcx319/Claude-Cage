// SPDX-License-Identifier: Apache-2.0

package macos

// macOS can publish the mount directory before cidata's executable is visible.
// Keep initialization bounded and fail on missing media; never fabricate the
// boot-complete marker that gates the host's remaining readiness checks.
const initScript = `#!/bin/sh
set -eux
date
attempt=0
while [ ! -x /Volumes/cidata/lima-guestagent ]; do
  if [ "$attempt" -ge 60 ]; then
    echo "cidata guest agent did not become ready" >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 1
done
exec /Volumes/cidata/lima-guestagent fake-cloud-init
`
