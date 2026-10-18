# Context Gateway contract test in ChappieClaw

This fork contains a provider-neutral test implementation of the Context Gateway contract from AllasCode in `src/coding/context_gateway.zig`.

The tests cover:

- accepting a candidate only when all caller-supplied validation flags are true and both byte and token counts strictly decrease;
- byte-identical fallback to the original request when validation is incomplete;
- rejecting invalid structured output and unauthorized tool calls;
- failing closed when the fixed-size audit journal is full;
- keeping raw payload bytes out of audit records.

The module is exported by `src/coding.zig`, which is already part of the root test graph. The existing CI workflow therefore runs these tests through `zig build test --summary all` using Zig 0.16.0.

## Scope and limitation

This verifies the gateway's contract and safety behavior inside ChappieClaw. It does **not** claim that the gateway is already intercepting real provider requests or responses. The current implementation is a tested boundary primitive; wiring it into the agent/provider inference path requires a separate change around the serialized request and response lifecycle.

The gateway does not independently prove that a transformation is lossless. Its caller must supply valid evidence for coverage, policy, cache compatibility, and token counts. FNV-1a fingerprints are for correlation only, not cryptographic integrity or authorization.
