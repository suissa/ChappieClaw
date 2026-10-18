# ChappieClaw + secondwind (ChappieContextCondenser)

This integration keeps the responsibilities separate:

- **ChappieClaw** owns agent state, tool execution, provider selection, and the Context Gateway admission boundary.
- **secondwind** (the upstream implementation behind the ChappieContextCondenser project) rewrites supported provider request formats and compresses eligible tool-output blocks using its own lossless-proof and net-cost gates.
- The local proxy is an opt-in deployment path. It is not the in-process `ContextTransformCallback` adapter, and it does not automatically populate the typed `Candidate` evidence used by ChappieClaw's internal gate.

## Proxy deployment

Run secondwind as a local proxy using the installation and commands documented by its upstream project:

```sh
secondwind serve
```

Configure the ChappieClaw OpenAI-compatible provider to use the local proxy URL as its `base_url` (for example, `http://127.0.0.1:8787/v1` only if that is the path exposed by the installed secondwind version). Keep the real upstream provider credentials and endpoint on the proxy side. Do not point the proxy's upstream URL back at itself.

The exact base URL/path must match the secondwind version and provider protocol in use. Verify with a small non-production request before routing a live agent session. For Anthropic-compatible providers, use secondwind's documented Anthropic Messages proxy configuration rather than assuming the OpenAI path applies.

## Safety and behavior boundaries

1. Keep this proxy optional. ChappieClaw must work unchanged when it is not configured.
2. Never treat a proxy's success response as proof that ChappieClaw's typed request gate independently verified semantic equivalence. The proxy's internal proof and ChappieClaw's admission evidence are separate contracts.
3. Do not send secrets, credentials, or raw prompts to telemetry. Use only the payload-free metadata already defined by the Context Gateway.
4. Keep provider/model/tool metadata stable when integrating an in-process transformer. The current callback contract is intended to replace messages only.
5. Streaming compatibility must be tested end to end for each provider. ChappieClaw's internal stream gate buffers chunks until final admission; the external proxy also has its own response/streaming behavior.
6. If proxy configuration or availability is uncertain, revert the provider base URL to the direct upstream endpoint. Do not silently enable a remote transformation service.

## Validation checklist

- [ ] Confirm the proxy's actual listening URL and API path from the installed version.
- [ ] Confirm one ordinary chat request reaches the intended upstream provider exactly once.
- [ ] Confirm tool output is compressed only when secondwind's lossless and net-cost gates admit it.
- [ ] Confirm tool calls, images/multimodal messages, and large payloads pass through correctly or are declined safely.
- [ ] Confirm streamed output and retries do not duplicate or leak partial responses.
- [ ] Compare provider usage/token counts before and after on the same representative tool-output fixture.
- [ ] Run ChappieClaw's Zig 0.16.0 formatting, test, build, and coding-contract CI jobs.

## Current limitation

This document describes a deployable proxy boundary, not a completed native Zig binding to secondwind's library. The `Agent.setContextTransformer` callback remains a separate extension point. A native adapter should only be added after the secondwind C ABI or stable library API, memory ownership rules, and proof/certificate interface have been pinned to a version and tested.