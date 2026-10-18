# ChappieClaw + secondwind (ChappieContextCondenser)

This integration keeps the responsibilities separate:

- **ChappieClaw** owns agent state, tool execution, provider selection, and the Context Gateway admission boundary.
- **secondwind** rewrites supported provider request formats and compresses eligible tool-output blocks behind its own lossless-proof and net-cost gates.
- The proxy is an opt-in deployment path. It is not the in-process Zig FFI adapter and does not automatically populate the typed Context Gateway evidence.

## Proxy deployment

Run `secondwind serve` and configure an OpenAI-compatible provider to use the actual base URL documented by the installed version. The upstream project documents the default listener on port 8787; do not assume that every provider uses a `/v1` suffix. Keep upstream credentials on the proxy side and never point the proxy upstream URL back to itself.

For Anthropic-compatible providers, use the documented Anthropic Messages route. Validate with a non-production request before routing live sessions.

## Native C ABI adapter

`src/coding/secondwind_ffi.zig` defines an opt-in, provider-neutral wrapper around the upstream C ABI. It is pinned to **ABI version 1** and the current upstream package/workspace version **0.3.2**. The host must load the matching native library and inject its exported symbols into `secondwind_ffi.Api`; this module intentionally does not introduce a hard link or enable transformation by default.

The wrapper covers:

- `sw_abi_version` — checked before each operation;
- `sw_compress` and `sw_verify` — UTF-8 JSON input/output;
- `sw_session_new`, `sw_rewrite`, and `sw_session_free` — explicit session lifecycle;
- `sw_free(pointer, length)` — releases each library-owned output exactly once.

Returned JSON is copied into the caller's allocator and the library allocation is freed, including when the response exceeds the 16 MiB adapter limit. Session creation and rewriting happen only after explicit calls by the host.

### Important evidence boundary

The FFI wrapper is transport and memory-ownership glue, not a proof adapter. In particular, `sw_rewrite` reports request/stats and internally applies secondwind's proof and net-cost gates, but the returned stats alone do not populate all fields in ChappieClaw's `context_request_gate.Candidate`. A follow-up must serialize only supported request fields, preserve provider/model/tools/generation settings, validate the returned JSON shape, and map independently checkable proof/token/coverage evidence before the Context Gateway may accept a replacement. Until then, keep the native wrapper opt-in and use the proxy path only as separately configured deployment infrastructure.

## Safety and behavior boundaries

1. No proxy or native transformation is activated by default.
2. A successful library/proxy call is not itself proof that ChappieClaw independently verified semantic equivalence.
3. Never send credentials or raw prompts to telemetry; use payload-free Context Gateway audit records.
4. Only message/tool-output content may be eligible for replacement. Provider, model, tools, session, and generation settings must remain unchanged.
5. The internal streaming gate buffers until final response admission, trading first-token latency for strict publication.
6. On ABI mismatch, malformed output, allocation failure, or uncertain configuration, retain the original request or fail closed according to the caller's explicit policy.

## Validation checklist

- [ ] Confirm the installed shared library exports ABI version 1 and all required symbols.
- [ ] Run Zig 0.16.0 formatting, tests, build, and coding-contract CI.
- [ ] Add host-loader integration tests for the actual library artifact on supported OS/architectures.
- [ ] Verify malformed/error JSON and output-size-limit behavior.
- [ ] Test request preservation for tools, multimodal content, retries, and streaming.
- [ ] Compare real tokenizer counts against the same fixture with and without transformation.
- [ ] Do not enable the typed request transformer until proof/coverage evidence is mapped and tested end to end.
