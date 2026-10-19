#!/bin/bash
# cn-llmrouter/tests/vm-e2e.sh — runs INSIDE the kora VM (amun/test --post)
# after amun core (and, with ./test --tailnet, amun tailscale) converged.
# Proves the router the way a new laptop would use it:
#   1. name + TLS trust (LAN: step-ca via the OS store; tailnet: LE)
#   2. catalogue, raw Anthropic + OpenAI protocols, count_tokens, fast failure
#   3. real clients installed like a laptop (gear qwen, native claude,
#      seshat install llm.client) and driven headless against the router
# Every check prints PASS/FAIL; the script exits non-zero if any FAIL.
# TS_AUTHKEY is filled in by ../test --tailnet (generated copy, never in git).
TS_AUTHKEY=
set -uo pipefail
URL="${LLMROUTER_URL:-https://llmrouter.lab.gn.al}"
HOST="${URL#https://}"; HOST="${HOST%%/*}"
FAST_BOX=qwen-minerva      # row expected to answer (../test --fast-box substitutes)
SLEEPY_BOX=qwen-klaus      # row expected to be asleep/off (../test --sleepy-box substitutes)
PASS=0; FAIL=0
ok()   { echo "[e2e] PASS: $*"; PASS=$((PASS+1)); }
bad()  { echo "[e2e] FAIL: $*" >&2; FAIL=$((FAIL+1)); }
note() { echo "[e2e] $*"; }
export PATH="$HOME/bin:$HOME/.local/bin:$PATH"
export DEBIAN_FRONTEND=noninteractive
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

note "guest: $(hostname) $(. /etc/os-release; echo "$PRETTY_NAME") arch=$(uname -m) user=$(id -un)"
command -v curl >/dev/null || sudo apt-get install -y -qq curl >/dev/null
command -v dig  >/dev/null || sudo apt-get install -y -qq dnsutils >/dev/null
command -v jq   >/dev/null || sudo apt-get install -y -qq jq >/dev/null

# ── 0. optional tailnet join ────────────────────────────────────────────────
if [ -n "$TS_AUTHKEY" ]; then
  command -v tailscale >/dev/null || bad "tailscale missing (run ./test --tailnet, which adds -p tailscale)"
  if sudo tailscale up --login-server=https://hs.gn.al --authkey="$TS_AUTHKEY" \
       --accept-dns --accept-routes --hostname=kora-e2e >/dev/null 2>&1; then
    ok "tailscale up (ephemeral node kora-e2e, ip $(tailscale ip -4))"
  else
    bad "tailscale up failed"
  fi
  sleep 3
  MODE=tailnet
else
  MODE=lan
fi

# ── 1. name + trust ─────────────────────────────────────────────────────────
RES="$(dig +short "$HOST" | tail -1)"
note "$HOST resolves to ${RES:-<nothing>} (mode=$MODE)"
case "$MODE:$RES" in
  lan:10.1.1.140)      ok "LAN DNS → kaiser ($RES)" ;;
  tailnet:100.64.0.1)  ok "MagicDNS → VPS traefik-lab ($RES)" ;;
  *)                   bad "unexpected resolution '$RES' for mode $MODE" ;;
esac
ISSUER="$(echo | openssl s_client -connect "$HOST:443" -servername "$HOST" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null)"
note "certificate issuer: ${ISSUER:-<none>}"
if curl -fsS --max-time 20 "$URL/health/liveliness" >/dev/null; then
  ok "https $URL/health/liveliness with the OS trust store (${ISSUER#issuer=})"
else
  bad "https liveliness failed — TLS trust (step-ca root in the OS store?) or routing"
fi

# ── 2. catalogue + raw protocols ────────────────────────────────────────────
MODELS="$(curl -fsS --max-time 20 "$URL/v1/models" | jq -r '.data[].id' | sort | tr '\n' ' ')"
note "catalogue: $MODELS"
for m in auto auto-claude deepseek-flash qwen-local qwen-think qwen-klaus qwen-minerva qwen-travelblock claude-opus claude-sonnet claude-haiku gpt-5.5; do
  case " $MODELS " in *" $m "*) ;; *) bad "catalogue lacks $m" ;; esac
done
ok "catalogue lists the expected rows"

# Anthropic Messages (what Claude Code speaks) → non-Anthropic upstream, streaming
OUT="$(curl -sN --max-time 120 "$URL/v1/messages" -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"deepseek-flash","max_tokens":32,"stream":true,"messages":[{"role":"user","content":"Reply with exactly the text ROUTER-OK and nothing else."}]}')"
# the answer arrives as several text_delta events ("RO", "UT", "ER-OK"): join them before matching
TEXT="$(grep '^data: ' <<<"$OUT" | sed 's/^data: //' | jq -r 'select(.type=="content_block_delta") | .delta.text // empty' 2>/dev/null | tr -d '\n')"
if grep -q 'ROUTER-OK' <<<"$TEXT" && grep -q 'event: message_start' <<<"$OUT"; then ok "/v1/messages streaming → deepseek-flash"; else bad "/v1/messages deepseek-flash: text='$TEXT' head=$(head -c 200 <<<"$OUT" | tr '\n' ' ')"; fi

# count_tokens is optional for Claude Code but must not 500
CT="$(curl -s --max-time 30 -o "$TMP/ct.json" -w '%{http_code}' "$URL/v1/messages/count_tokens" -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"deepseek-flash","messages":[{"role":"user","content":"hello there"}]}')"
if [ "$CT" = 200 ] && jq -e '.input_tokens > 0' "$TMP/ct.json" >/dev/null 2>&1; then ok "count_tokens → $(jq -r .input_tokens "$TMP/ct.json") tokens"; else note "count_tokens http=$CT (optional for Claude Code)"; fi

# OpenAI Chat Completions (what qwen-code speaks)
chat() { # $1 model, $2 max seconds → prints content; header x-litellm-model-id to stderr
  curl -s --max-time "$2" -D "$TMP/h.$1" "$URL/v1/chat/completions" -H 'content-type: application/json' \
    -d "{\"model\":\"$1\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly the text ROUTER-OK and nothing else.\"}],\"max_tokens\":32}" \
    | jq -r '.choices[0].message.content // .error.message // .' 2>/dev/null
}
for m in "$FAST_BOX" qwen-local claude-haiku gpt-5.5; do
  R="$(chat "$m" 300)"
  if grep -q 'ROUTER-OK' <<<"$R"; then
    ok "/v1/chat/completions → $m (served by $(grep -i '^x-litellm-model-id' "$TMP/h.$m" | awk '{print $2}' | tr -d '\r'))"
  else
    bad "/v1/chat/completions $m: $(head -c 200 <<<"$R")"
  fi
done
# a sleeping box must fail fast (tcp_syn_retries=3 in the sidecar), not hang
S=$(date +%s); R="$(chat "$SLEEPY_BOX" 60)"; D=$(( $(date +%s) - S ))
if grep -q 'ROUTER-OK' <<<"$R"; then note "$SLEEPY_BOX answered in ${D}s (box is up — fast-fail check skipped)";
elif [ "$D" -le 30 ]; then ok "$SLEEPY_BOX failed fast in ${D}s"; else bad "$SLEEPY_BOX took ${D}s to fail"; fi

# ── 3. clients, installed like a laptop ─────────────────────────────────────
if ! command -v node >/dev/null 2>&1 || [ "$(node -v | cut -c2- | cut -d. -f1)" -lt 22 ]; then
  note "installing Node 22 (NodeSource)"
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - >/dev/null 2>&1
  sudo apt-get install -y -qq nodejs >/dev/null 2>&1
fi
node -v >/dev/null 2>&1 && ok "node $(node -v)" || bad "node missing"
if ! command -v qwen >/dev/null 2>&1; then
  note "installing qwen-code via gear com/qwen"
  [ -x "$HOME/.gear/com/qwen/setup-debian" ] && "$HOME/.gear/com/qwen/setup-debian" >/dev/null 2>&1
fi
command -v qwen >/dev/null 2>&1 && ok "qwen $(qwen --version 2>/dev/null | head -1)" || bad "qwen missing (gear com/qwen)"
if ! command -v claude >/dev/null 2>&1; then
  note "installing Claude Code (native installer)"
  curl -fsSL https://claude.ai/install.sh | bash >/dev/null 2>&1
fi
command -v claude >/dev/null 2>&1 && ok "claude $(claude --version 2>/dev/null | head -1)" || bad "claude missing"

if [ -x "$HOME/.dotfiles/seshat" ]; then
  if "$HOME/.dotfiles/seshat" install llm.client --yes >"$TMP/seshat.log" 2>&1; then
    ok "seshat install llm.client"
  else
    bad "seshat install llm.client (rc=$?): $(tail -3 "$TMP/seshat.log" | tr '\n' ' ')"
  fi
  "$HOME/.dotfiles/seshat" list 2>/dev/null | grep -E 'llm\.client' | head -1
else
  bad "~/.dotfiles/seshat missing (amun dotfiles role did not run?)"
fi
jq -e '.env.ANTHROPIC_BASE_URL' "$HOME/.claude/settings.json" >/dev/null 2>&1 && ok "claude settings → $(jq -r .env.ANTHROPIC_BASE_URL "$HOME/.claude/settings.json")" || bad "claude settings lack env.ANTHROPIC_BASE_URL"
jq -e '.modelPicker.options | length > 0' "$HOME/.claude/settings.json" >/dev/null 2>&1 && ok "claude modelPicker rows: $(jq -r '[.modelPicker.options[].model] | join(" ")' "$HOME/.claude/settings.json")" || bad "claude modelPicker missing"
jq -e '.modelProviders.openai | length > 0' "$HOME/.qwen/settings.json" >/dev/null 2>&1 && ok "qwen providers: $(jq -r '[.modelProviders.openai[].id] | join(" ")' "$HOME/.qwen/settings.json")" || bad "qwen settings lack modelProviders"
# Node CA export from the dotfiles bashrc fragment (needed for qwen on the LAN path)
# the dotfiles bashrc only runs for interactive shells → ask an interactive one
CA_LINE="$(bash -ic 'echo "${NODE_EXTRA_CA_CERTS:-}"' 2>/dev/null | tail -1)"
if [ "$MODE" = lan ]; then
  [ -n "$CA_LINE" ] && [ -r "$CA_LINE" ] && ok "interactive shell exports Node CA ($CA_LINE)" || bad "no NODE_EXTRA_CA_CERTS in an interactive shell (qwen-code would reject the step-ca leaf); root present: $(ls /usr/local/share/ca-certificates/ 2>/dev/null | tr '\n' ' ')"
else
  [ -n "$CA_LINE" ] && ok "interactive shell exports Node CA ($CA_LINE)" || note "no NODE_EXTRA_CA_CERTS in an interactive shell (not needed on the tailnet path)"
fi

run_claude() { # $1 model — interactive shell, like a human's terminal (bashrc exports apply)
  bash -ic "timeout 600 claude -p --model '$1' 'Reply with exactly the text ROUTER-OK and nothing else.' 2>&1"
}
for m in auto deepseek-flash claude-haiku; do
  R="$(run_claude "$m")"
  if grep -q 'ROUTER-OK' <<<"$R"; then ok "claude -p --model $m"; else bad "claude -p --model $m: $(tail -c 300 <<<"$R")"; fi
done
# one tool-use turn through the translation layer (DeepSeek via /v1/messages)
# prompt on stdin: --allowedTools takes a list and would swallow a trailing positional prompt
R="$(bash -ic "echo 'Run ls /etc/hostname with the Bash tool and then reply with exactly TOOL-OK.' | timeout 600 claude -p --model deepseek-flash --allowedTools 'Bash(ls:*)' 2>&1")"
if grep -q 'TOOL-OK' <<<"$R"; then ok "claude tool-use turn via deepseek-flash"; else bad "claude tool-use: $(tail -c 300 <<<"$R")"; fi

run_qwen() { # $1 model — interactive shell so NODE_EXTRA_CA_CERTS applies on the LAN path
  bash -ic "timeout 900 qwen -p 'Reply with exactly the text ROUTER-OK and nothing else.' --model '$1' 2>&1"
}
for m in deepseek-flash "$FAST_BOX"; do
  R="$(run_qwen "$m")"
  if grep -q 'ROUTER-OK' <<<"$R"; then ok "qwen -p --model $m"; else bad "qwen -p --model $m: $(tail -c 300 <<<"$R")"; fi
done

# ── 4. negatives ────────────────────────────────────────────────────────────
if curl -s --max-time 5 http://kaiser.lan:4000/ >/dev/null 2>&1; then bad "kaiser.lan:4000 reachable from the LAN (should be loopback-only)"; else ok "kaiser.lan:4000 is not exposed on the LAN"; fi

echo "[e2e] ==== $PASS passed, $FAIL failed (mode=$MODE) ===="
[ "$FAIL" -eq 0 ]
