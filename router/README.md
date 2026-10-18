# router/

Custom LiteLLM Auto Router classifier plugins (Phase 3). Mounted read-only at
`/app/router` in the `litellm` container and referenced from `config.yaml` as
`classifier_plugin: router.<module>.<instance>`.

Planned first plugin: route Claude Code `x-claude-code-request-class`
`compaction`/`auxiliary` and `Explore`-subagent traffic to the SIMPLE tier
unconditionally, then defer to the built-in heuristic.
