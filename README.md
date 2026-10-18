# cn-llmrouter

One LLM gateway for the homelab: a [LiteLLM](https://docs.litellm.ai) proxy on
`kaiser.lan` at **`https://llmrouter.lab.gn.al`**, reachable on the LAN and on
the tailnet with the same name. It owns the model catalogue; Claude Code and
qwen-code pick a row with `/model`. Virtual rows route by complexity (local
Qwen for easy turns, DeepSeek on Fireworks or Claude on Bedrock for hard ones).
No API key by operator decision — the Headscale ACL and the LAN are the trust
boundary, exactly like the llama-servers it fronts.

| Surface | Path | Cert |
|---|---|---|
| Tailnet | `llmrouter.lab.gn.al` → VPS `traefik-lab` (consul-register) → `llmrouter.ts.gn.al:4000` | LE wildcard |
| LAN | `llmrouter.lab.gn.al` → pfSense/Technitium → kaiser `cn-home/traefik-lan` → `127.0.0.1:4000` | step-ca leaf (amun's pki role trusts it; Node CLIs via the dotfiles `NODE_EXTRA_CA_CERTS` export) |
| kaiser only | `http://127.0.0.1:4000` | — |

## Point your client here

```sh
seshat install llm.client                         # Claude Code + qwen-code → the router
seshat install llm.client --set local_host=127.0.0.1   # a serving Mac / travelblock: also keep direct entries for offline use
claude   # /model shows the rows below; `claude --model qwen-minerva -p '…'` works too
qwen     # /model lists every row, including the think variants
```

The bundle sets `ANTHROPIC_BASE_URL`, a dummy `ANTHROPIC_AUTH_TOKEN` and a blank
`ANTHROPIC_API_KEY` (so Claude Code stays on the gateway), `ANTHROPIC_MODEL=auto`,
`CLAUDE_CODE_GATEWAY_HINT_HEADERS=1` (request-class hints for the router), and a
`modelPicker` with the rows below. For qwen-code it writes one `modelProviders`
entry per row with the right context window. Change the default with
`--set default_model=<row>`; re-point with `--set router_url=…`.

Any OpenAI- or Anthropic-API client works: `curl https://llmrouter.lab.gn.al/v1/models`.

### Catalogue

| `/model` row | What answers | Notes |
|---|---|---|
| `auto` | local Qwen pool for SIMPLE/MEDIUM turns, `deepseek-flash` for COMPLEX/REASONING | heuristic on the **last user turn**, session-pinned (a tool loop never switches model), escalates when the prompt outgrows the local window; falls to DeepSeek when no box is up |
| `auto-claude` | same split, hard tier on `claude-sonnet` | |
| `deepseek-flash` | DeepSeek 4.1 Flash on Fireworks over its Anthropic-compatible endpoint | 1M context, $0.30/$1.20 per 1M in/out; the path minerva used directly before the router |
| `qwen-local` / `qwen-think` | first local box that is up, in order minerva → klaus → travelblock (LAN), then klaus/travelblock over the tailnet | a failing box is cooled down for 2 min; the think rows use the reasoning alias |
| `qwen-klaus`, `qwen-minerva`, `qwen-travelblock` (+ `-think`) | that box only | a sleeping box is an error in ~7 s, not a silent reroute |
| `claude-opus`, `claude-sonnet`, `claude-haiku` | AWS Bedrock us-east-2 | Fable is not available on this account (data-retention 400) |
| `gpt-5.5` | GPT-5.5 on Bedrock (native Chat Completions) | mantle fallback form documented in `config.yaml` |

The local boxes run gear `localllm` in llama-server **router mode** with the same
two aliases everywhere (`qwen3.8-27b-code`, `qwen3.8-27b-think`); klaus and minerva
serve on demand (`tmux new -s llm 'localllm serve'`), travelblock from power-on.
They are pinned on the Wi-Fi VLAN by pfSense static mappings (cn-home
`LAN_STATIC_MAPPINGS`): klaus `10.2.0.31`, minerva `10.2.0.32`, travelblock
`10.2.0.33` (`klaus.lan` etc. in Technitium). The router addresses them by IP
because `.lan` does not resolve inside a Tailscale sidecar netns.

## Services

| Service | Image | Net | Purpose |
|---|---|---|---|
| `ts-llmrouter` | `tailscale/tailscale:latest` | kernel TUN | Sidecar — tailnet node `llmrouter` (`tag:svc`); publishes `127.0.0.1:4000` for cn-home Traefik; `tcp_syn_retries=3` so sleeping boxes fail fast |
| `litellm` | `ghcr.io/berriai/litellm:v1.106.0` (pinned) | `service:ts-llmrouter` | The proxy: `/v1/messages`, `/v1/chat/completions`, `/v1/models`, `/metrics`, `/health/liveliness` |
| `consul-register` | `curlimages/curl:8.8.0` | `service:ts-llmrouter` | PUTs `llmrouter` into VPS Consul every 60 s → `Host(llmrouter.lab.gn.al)` via `llmrouter.ts.gn.al:4000` |
| `promtail` | `grafana/promtail:3.4.2` | `service:ts-llmrouter` | Stack logs → VPS Loki (`stack="cn-llmrouter"`) |
| `ts-llmrouter-watchdog` | `docker:cli` | — | Force-recreates `litellm consul-register promtail` on sidecar netns drift (3-poll threshold) |

Project subnet `172.30.7.0/24` (fleet sequence after cn-nvr `.6`). No database:
`config.yaml` in git is the only state.

## Setup

```sh
git clone https://github.com/GonzaloAlvarez/cn-llmrouter.git ~/cn-llmrouter
cd ~/cn-llmrouter
kauket get kaiser.cn_llmrouter_env   # installs .env (0600): authkey, provider keys, backend URLs
./setup.sh                           # step-ca root + compose up
amun docker                          # resiliency.yml → boot unit + 5-min reconcile cron
```

Shared infrastructure wired for this stack: consul-register (tailnet name),
cn-home `traefik-lan` router + `LAN_HOSTS` (LAN name), cn-dnsdhcpd records,
Headscale ACL `tag:svc → klaus:8080, travelblock:8080`, VPS Prometheus job
`llmrouter` + blackbox probe + `LLMRouterDown`/`LLMRouterDeploymentFailures`
alerts, Glance and dynacat entries. Deliberately skipped: backups (stateless),
node-exporter (kaiser's host metrics suffice), Authentik (API clients with bearer
tokens, no browser gate — and no key at all here).

## Operations

```sh
docker compose -p cn-llmrouter ps
docker logs -f cn-llmrouter-litellm-1
curl -s http://127.0.0.1:4000/v1/models | jq -r '.data[].id'
# catalogue change: edit config.yaml, commit, then (single-file bind mount → recreate)
git pull && docker compose up -d --force-recreate --no-deps litellm
# secret rotation: kauket add … --force on the Mac, then here
rm .env && kauket get kaiser.cn_llmrouter_env && docker compose up -d --force-recreate
```

Which box served a request: response header `x-litellm-model-id`, LiteLLM logs,
or the VPS Grafana `llmrouter` dashboard (per-deployment success/failure/latency,
cooldowns, tokens, spend).

## Testing — end to end from a fresh VM

```sh
./test                    # kora debian VM on this Mac: LAN client path (step-ca)
./test debian --tailnet   # same, after joining the tailnet with an ephemeral key (LE path)
./test arch               # optional second platform
DEBUG=1 ./test            # shell in the VM before teardown
```

`test` drives `amun/test --post tests/vm-e2e.sh`: the guest converges amun core
(step-ca trust, seshat dotfiles), installs qwen-code (gear) and Claude Code (native
installer), runs `seshat install llm.client`, then exercises the router with raw
Anthropic/OpenAI calls and real `claude -p` / `qwen -p` turns, including one
tool-use turn through the translation layer and a fast-fail check against a
sleeping box. Prerequisites: dotfiles `main` carries `llm.client`; minerva is
serving (`E2E_FAST_BOX`), klaus is not (`E2E_SLEEPY_BOX`).

## Troubleshooting

- **A local row hangs or errors**: the box is asleep/off or still loading the
  model (`curl http://<ip>:8080/health` → 503 while loading). The pool skips it
  for `cooldown_time`; `qwen-<box>` rows fail on purpose. If the box's address
  changed, the pfSense static mapping did not apply (macOS *Private Wi-Fi
  Address* must stay **Fixed** for the home SSID; re-map on MAC change).
- **`TRAEFIK DEFAULT CERT` on the LAN name**: step-ca HTTP-01 failed → the
  pfSense Host Override or the Technitium record is missing (`cn-home/deploy`,
  `cn-dnsdhcpd/seed-dns.sh`).
- **qwen-code `UNABLE_TO_VERIFY_LEAF_SIGNATURE` on the LAN**: Node does not read
  the OS trust store; open a new shell (dotfiles export `NODE_EXTRA_CA_CERTS`), or
  on macOS export the root once: `security find-certificate -c cn-pki-root -p > ~/.config/cn-pki/root_ca.crt`.
- **Claude Code ignores the router**: `ANTHROPIC_API_KEY` must be unset or blank
  (the bundle writes `""`); check `claude --debug` for the base URL.
- **count_tokens 404 from Fireworks**: expected; LiteLLM counts with tiktoken and
  Claude Code treats the endpoint as optional.
- **Bedrock 400 "data retention mode"**: Fable models are not available on this
  account; use `claude-opus` / `claude-sonnet`.
- **LiteLLM refuses to start, "no master key"**: `general_settings.dangerously_permit_weak_or_unset_master_key: true`
  is the deliberate keyless opt-out — keep it, or add a master key and virtual keys
  (then enroll the laptops in kauket; not done by design).
- **Deployment failures alert for a cloud model**: bad key, quota, or a model id
  change upstream — `docker logs cn-llmrouter-litellm-1`.

## Known limits

A dense 27B processes prompts at ~160 tok/s on klaus and ~55 tok/s on
travelblock: a cold Claude Code turn (~30k tokens of system prompt and tools)
takes minutes on the local tier, and a 32–64k window cannot hold a long Claude
Code session — `auto` escalates on length and the dependable local savings are
compaction/auxiliary/subagent traffic and qwen-code sessions (~14k system
prompt). Per-turn difficulty scoring of coding prompts is a cost saver, not a
quality guarantee; measure on the dashboard before trusting it.
