"""cn-llmrouter — Auto Router classifier plugin: Claude Code hint headers first.

Claude Code (>= 2.1.273, with CLAUDE_CODE_GATEWAY_HINT_HEADERS=1) labels every
request: x-claude-code-request-class is main | subagent | compaction |
auxiliary, x-claude-code-agent-type names the subagent. Compaction summaries,
auxiliary calls (titles, suggestions) and Explore subagents are the traffic
that never needs the expensive tier, so they go to SIMPLE (the local Qwen
pool) unconditionally. Everything else returns None, which hands the turn to
the built-in heuristic (classifier_fallback: heuristic in config.yaml).

Referenced from config.yaml as `classifier_plugin: router.hints.hints`
(module path resolved next to the config file; ./router is mounted at
/app/router).
"""
from __future__ import annotations

import logging
from typing import Any, Optional

log = logging.getLogger("litellm")

CHEAP_REQUEST_CLASSES = {"compaction", "auxiliary"}
CHEAP_AGENT_TYPES = {"explore"}
_HEADER_KEYS = ("headers", "request_headers", "proxy_server_request", "litellm_metadata")


def _headers(context: Any) -> dict[str, str]:
    """Best-effort extraction of the inbound HTTP headers from RoutingContext.metadata."""
    md = getattr(context, "metadata", None) or {}
    if not isinstance(md, dict):
        return {}
    for key in _HEADER_KEYS:
        value = md.get(key)
        if isinstance(value, dict) and key in ("proxy_server_request", "litellm_metadata"):
            value = value.get("headers")
        if isinstance(value, dict):
            return {str(k).lower(): str(v) for k, v in value.items()}
    return {}


class ClaudeCodeHints:
    _logged_shape = False

    async def classify(self, context: Any) -> Optional[str]:
        headers = _headers(context)
        if not headers and not ClaudeCodeHints._logged_shape:
            md = getattr(context, "metadata", None) or {}
            log.info("cn-llmrouter hints: no headers found in RoutingContext.metadata keys=%s",
                     sorted(md.keys())[:30] if isinstance(md, dict) else type(md).__name__)
            ClaudeCodeHints._logged_shape = True
        request_class = headers.get("x-claude-code-request-class", "").lower()
        agent_type = headers.get("x-claude-code-agent-type", "").lower()
        if request_class in CHEAP_REQUEST_CLASSES or agent_type in CHEAP_AGENT_TYPES:
            log.info("cn-llmrouter hints: request_class=%s agent_type=%s -> SIMPLE", request_class, agent_type)
            return "SIMPLE"
        return None


hints = ClaudeCodeHints()
