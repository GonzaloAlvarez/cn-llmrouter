Last verified 2026-10-18. Source of truth for the mechanics: `cn-llmrouter` (the router, `config.yaml` is the catalogue), the dotfiles bundle `llm.client` (the clients), `localllm.server` + gear `localllm` (the local servers), and the host rows in `homelab/architecture.md`. This page replaces "Local LLMs across the homelab — where to point your client".

## One address

Every client points at **`https://llmrouter.lab.gn.al`** — the LiteLLM gateway on kaiser. The same name works on the LAN (pfSense/Technitium → kaiser, step-ca certificate) and on the tailnet (`ts up` → VPS traefik-lab, Let's Encrypt). There is no API key: the Headscale ACL and the LAN are the trust boundary, exactly like the llama-servers behind it. The router owns the model list; you pick a row with `/model`.

```sh
seshat install llm.client                          # Claude Code + qwen-code → the router (any personal Mac or Linux box)
seshat install llm.client --set local_host=127.0.0.1   # on a serving machine: also keep DIRECT entries to its own llama-server
claude                                             # /model lists the rows below
qwen                                               # /model lists every row incl. the think variants
```

Prerequisites once per machine: `claude --version` (native installer) and `qwen --version` (gear com/qwen; Linux needs Node ≥ 20 from the package manager or NodeSource). The bundle writes `~/.claude/settings.json#/env` + `#/modelPicker` and `~/.qwen/settings.json` + `~/.qwen/.env`; it replaced `llm.claude.bedrock` and `llm.qwen.local` (Bedrock and the local servers are router rows now). Re-point with `--set router_url=…`, change the startup row with `--set default_model=…`.

## The rows

| `/model` | What answers | When to use it |
|---|---|---|
| **`auto`** (default) | local Qwen pool for easy turns, DeepSeek 4.1 Flash for hard ones | everyday; classifies the last user turn, pins the model for the whole tool loop, escalates on long prompts, falls to DeepSeek when no box is up. Claude Code's compaction/auxiliary/Explore traffic always goes local |
| `auto-claude` | same split, hard tier on Claude Sonnet (Bedrock) | when you want Claude quality for the hard turns |
| `deepseek-flash` | DeepSeek 4.1 Flash on Fireworks (Anthropic-compatible endpoint, 1M context) | the default workhorse before the router existed; cheapest strong model |
| `qwen-local` / `qwen-think` | first local box that is up: minerva → klaus → travelblock (LAN), then klaus/travelblock over the tailnet | free; `-think` = reasoning on |
| `qwen-minerva`, `qwen-klaus`, `qwen-travelblock` (+ `-think`) | that box only | pick a machine explicitly; a sleeping box errors in ~4 s instead of rerouting |
| `claude-opus`, `claude-sonnet`, `claude-haiku` | AWS Bedrock us-east-2 | Fable is not available on this account |
| `gpt-5.5` | GPT-5.5 on Bedrock | |

Health check from anywhere: `curl https://llmrouter.lab.gn.al/v1/models`. Which box served a request: response header `x-litellm-model-id`, or the VPS Grafana dashboard **llmrouter**.

## The local servers

All three run gear `localllm` in llama-server **router mode** with the same two aliases (`qwen3.8-27b-code` thinking off, `qwen3.8-27b-think` reasoning effort medium), one resident at a time (alias swap ≈ 10 s, page-cached).

| Server | Address | Model | Speed | Availability |
|---|---|---|---|---|
| **minerva** (Mac, M4 Pro 48 GB) | `minerva.lan` = `10.2.0.32` (pfSense static lease); no tailnet | Qwen3.8-27B UD-Q6_K, ctx 32768 | ≈10 tok/s, ≈120 tok/s prompt | on demand: `tmux new -s llm 'localllm serve'`; usually left serving |
| **klaus** (MacBook, M4 Max) | `klaus.lan` = `10.2.0.31`; tailnet 100.64.0.37 when `ts up` | Qwen3.8-27B UD-Q6_K, ctx 65536, MTP | ≈14 tok/s warm, ≈160 tok/s prompt | on demand; a closed lid sleeps |
| **travelblock** (Minisforum EM780, Debian 13) | `travelblock.lan` = `10.2.0.33`; `travelblock.local` (mDNS); tailnet 100.64.0.44 (`tag:svc`) | Qwen3.8-27B UD-Q3_K_XL, ctx 32768, MTP both aliases | ≈9 tok/s, ≈55 tok/s prompt | automatic from power-on (`systemd --user` + linger); unloads after 30 idle min |

The router addresses the boxes by these pinned addresses (a Tailscale sidecar netns cannot resolve `.lan`). klaus and minerva use macOS *private Wi-Fi addresses*: they must stay **Fixed** for the home SSID or the static lease stops matching — if a box gets a different address, re-map it in `cn-home` `LAN_STATIC_MAPPINGS` and the router's `.env`.

Which to prefer: a Mac when one is serving (higher-quality quant, three times faster prompt processing); travelblock is the always-on fallback at home and the only box on the road. Honest limit: a dense 27B needs minutes for a cold Claude Code turn (~30k tokens of system prompt and tools) and its 32–64k window cannot hold a long Claude Code session — `auto` escalates on length; the dependable local savings are compaction/auxiliary/subagent traffic and qwen-code sessions (~14k system prompt).

## Situations

| You are | Do |
|---|---|
| Home, any personal machine | nothing special — `llmrouter.lab.gn.al` resolves on the LAN (step-ca; amun's pki role trusts it; qwen-code gets the root through the dotfiles `NODE_EXTRA_CA_CERTS` export — on macOS export the keychain root once: `security find-certificate -c cn-pki-root -p > ~/.config/cn-pki/root_ca.crt`) |
| Away, personal machine | `ts up` — the same name now resolves to the VPS (Let's Encrypt). The local rows work only for boxes that are on the tailnet and awake (klaus with `ts up`, travelblock powered on) |
| Travelling with travelblock, no internet | the router is unreachable; use the direct entries: `seshat install llm.client --set local_host=travelblock.local` (or the travel router's lease IP) and pick `qwen3.8-27b-code` / `-think` in qwen-code |
| A serving Mac without network | `--set local_host=127.0.0.1` keeps direct entries to its own server |
| Work Mac at home | never on the tailnet, but on the LAN: `https://llmrouter.lab.gn.al` works directly (trust the step-ca root for Node as above) |
| Work Mac away | the lab is reachable only through the cn-socksnode proxy, which Claude Code and qwen-code cannot use; forward the router over SSH instead: `ssh -o 'ProxyCommand=nc -x 127.0.0.1:1055 %h %p' -i ~/.ssh/gonzalo_main_private_key.pem -N -L 14000:127.0.0.1:4000 gonzalo@kaiser.lan` then `seshat install llm.client --set router_url=http://127.0.0.1:14000`; back home `--set router_url=https://llmrouter.lab.gn.al` |

## Operating the pieces

```sh
# router (kaiser)
docker compose -p cn-llmrouter ps; docker logs -f cn-llmrouter-litellm-1
git pull && docker compose up -d --force-recreate --no-deps litellm   # after a config.yaml change
# a Mac server
tmux new -s llm 'localllm serve'   # start;  localllm status | localllm stop
seshat install localllm.server --set <var>=<value>   # change a setting, then restart serve
# travelblock
systemctl --user status localllm; journalctl --user -u localllm -f
```

travelblock keeps its tuned settings (`ngl=all`, `server_env=GGML_VK_PREFER_HOST_MEMORY=1`, `kv_quant=q8_0`, `sleep_idle=1800`, MTP on both aliases) and the kernel GTT parameters (`amdgpu.gttsize=22528 ttm.pages_limit=5767168 ttm.page_pool_size=2883584`) — without them the Vulkan device is lost once a long prompt grows the KV cache past the default 14.5 GiB pool. If first-turn latency bites, the designed-in alternative is a 3B-active MoE pair (Qwen3-Coder-30B-A3B / Qwen3.6-35B-A3B) installed with `--set model_file=… model_sha256=… model2_hf_repo=… model2_file=… model2_sha256=…`.

Adding a model or a combination = a few lines in `cn-llmrouter/config.yaml` plus a row in the `llm.client` templates; the end-to-end test (`cn-llmrouter/test`) proves it from a fresh VM.
