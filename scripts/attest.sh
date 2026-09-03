#!/usr/bin/env bash
# Run one pipeline step under cilock so its inputs, outputs and result are signed and
# uploaded to the TestifySec platform. Mirrors the platform's own .github/actions/cilock-step.
#
# env:  STEP           collection name, stable across runs ([A-Za-z0-9._-])
#       ATTESTATIONS   space- or comma-separated attestor list (product + material always run)
#       PRODUCT_GLOB   glob for the product attestor (default *)
#       COMMAND        the shell command to run (bash, set -e, cwd = repo root)
#       PLATFORM_URL   default https://platform.testifysec.com
set -uo pipefail
: "${STEP:?STEP is required}"; : "${COMMAND:?COMMAND is required}"
PLATFORM_URL="${PLATFORM_URL:-https://platform.testifysec.com}"
ATTESTATIONS="${ATTESTATIONS:-environment git github}"
PRODUCT_GLOB="${PRODUCT_GLOB:-*}"

case "${STEP}" in *[!A-Za-z0-9._-]*|"") echo "::error::attest: bad STEP '${STEP}'"; exit 1;; esac

cmd_file="$(mktemp "${RUNNER_TEMP:-/tmp}/attest-cmd.XXXXXX")"
{ echo 'set -e'; echo 'cd "${GITHUB_WORKSPACE:-$PWD}"'; printf '%s\n' "${COMMAND}"; } > "${cmd_file}"

echo "attest[${STEP}]: cilock run (attestors=${ATTESTATIONS}, glob=${PRODUCT_GLOB}, platform=${PLATFORM_URL})"
cilock run \
  --step "${STEP}" \
  --platform-url "${PLATFORM_URL}" \
  --archivista-server "${PLATFORM_URL}/archivista" \
  --enable-archivista \
  --attestations "$(printf '%s' "${ATTESTATIONS}" | tr ' ' ',')" \
  --attestor-product-include-glob "${PRODUCT_GLOB}" \
  -- bash "${cmd_file}"
rc=$?
if [ "${rc}" -eq 0 ]; then
  echo "attest[${STEP}]: attested OK — signed keyless, uploaded to ${PLATFORM_URL}/archivista"
  exit 0
fi
echo "::error::attest[${STEP}]: cilock run exited ${rc} — no evidence minted for this step"
exit "${rc}"
