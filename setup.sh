#!/usr/bin/env bash
# cn-llmrouter — idempotent bring-up.
#
# The .env is Kauket-managed (secret id kaiser.cn_llmrouter_env); the
# Headscale authkey and provider keys are NOT minted here. This script
# fetches the step-ca root for the sidecar, validates .env, and brings the
# stack up.
#
#   kauket get kaiser.cn_llmrouter_env   # installs .env (0600)
#   ./setup.sh
#
# Model catalogue changes live in config.yaml (git); apply them with
#   docker compose up -d --force-recreate --no-deps litellm
set -euo pipefail

cd "$(dirname "$0")"

case "${1:-}" in
  -h|--help)
    sed -n '/^#!/d; /^[^#]/q; s/^# \{0,1\}//p' "$0"
    exit 0
    ;;
  "") ;;
  *)
    echo "unknown argument: $1 (try --help)" >&2
    exit 2
    ;;
esac

log() { printf '\n\033[1;36m[setup]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

env_get() { grep -E "^${1}=" .env 2>/dev/null | head -1 | cut -d= -f2- || true; }

[[ -f .env ]] || die ".env not found. Run: kauket get kaiser.cn_llmrouter_env"
for key in LLMROUTER_AUTHKEY HEADSCALE_DOMAIN INFRA_VPS_TAILNET_IP LAB_DOMAIN TAILNET_DOMAIN \
           FIREWORKS_AI_API_KEY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION_NAME \
           QWEN_KLAUS_BASE QWEN_MINERVA_BASE QWEN_TRAVELBLOCK_BASE QWEN_KLAUS_TS_BASE QWEN_TRAVELBLOCK_TS_BASE; do
  [[ -n "$(env_get "$key")" ]] || die ".env: $key is empty"
done

# ── step-ca root CA (sidecar SSL_CERT_DIR) ──────────────────────────────────
mkdir -p certs
PKI_IP_VAL="$(env_get PKI_IP)"
PKI_IP_VAL="${PKI_IP_VAL:-pki.lan}"
if [[ ! -f certs/root_ca.crt ]]; then
  log "fetching step-ca root CA from http://${PKI_IP_VAL}/cert/ca.crt"
  curl -sSf "http://${PKI_IP_VAL}/cert/ca.crt" -o certs/root_ca.crt \
    || die "could not fetch root CA from ${PKI_IP_VAL}"
fi

# ── Bring the stack up ──────────────────────────────────────────────────────
log "docker compose up -d --remove-orphans"
docker compose up -d --remove-orphans

LAB_DOMAIN_VAL="$(env_get LAB_DOMAIN)"
cat <<MSG


===============================================================
cn-llmrouter stack is up.

  Clients  :  https://llmrouter.${LAB_DOMAIN_VAL}
              tailnet -> VPS traefik-lab (LE); LAN -> kaiser traefik-lan (step-ca)
  Local    :  http://127.0.0.1:4000/v1/models   (on kaiser)
  Health   :  /health/liveliness   Metrics: /metrics

  Catalogue: config.yaml  -> docker compose up -d --force-recreate --no-deps litellm
  The .env (authkey + provider keys + backend URLs) is Kauket-managed
  (kaiser.cn_llmrouter_env).
===============================================================
MSG
