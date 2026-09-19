# Coding Agent implementation backlog

GitHub Issues are enabled. The implementation tracks below are now represented by Issues #2 through #11.

1. **#2 — feat(coding): explicit Coding Agent lifecycle with hypothesis-before-mutation**
   - Add `inspect -> hypothesize -> plan -> mutate -> verify -> prove -> done`.
   - Reject mutation before hypothesis/plan and proof before verification.

2. **#3 — feat(skills): consume AllasCode atomic Action SKILLs as canonical coding knowledge**
   - Support semantics/authoring/healing projections, canonical labels, retrieval metadata, relations, and authority.

3. **#4 — feat(skills): semantic Skill Resolver and bounded context composition**
   - Resolve by language, artifact, canonical label, symbol, concept, diagnostic, and relation.
   - Bound skill count/context bytes and preserve provenance.

4. **#5 — feat(tools): coding-specific search/build/test/lint/format/diagnostics tools**
   - Add language-aware adapters for Zig, Rust, Go, and TypeScript.

5. **#6 — feat(safety): hashed mutation, workspace policy, and change guards**
   - Prefer hashed edits, reject stale state, constrain paths/commands, define revert boundary.

6. **#7 — feat(agents): CodeManager, CodeHealer, and independent HealingVerifier profiles**
   - Separate contexts and tool authority. Verifier must not inherit healer reasoning.

7. **#8 — feat(healing): successful verified fixes become candidate Healing SKILLs**
   - Candidate -> validate -> promote. Failed/inconclusive results cannot become trusted.

8. **#9 — feat(acp): coding sessions through Agent Client Protocol**
   - Bind workspace and expose phase/diagnostic/verification state without bypassing policy.

9. **#10 — feat(observability): coding lineage, skill provenance, mutation and proof evidence**
   - Record hashes/IDs/evidence, not secrets or unnecessary source payloads.

10. **#11 — docs(test): Coding Agent contract and end-to-end acceptance suite**
   - Cover compile failure healing, stale hash rejection, workspace escape rejection, verifier independence, and healing-skill promotion.

## Current implementation status

The first implementation slice on `feat/allascode-coding-agent` starts all ten tracks:
- lifecycle policy and tests;
- canonical atomic-skill contract and deterministic scoring;
- bounded resolver configuration surface;
- language-aware coding command catalog;
- authority profiles;
- healing candidate promotion rules;
- ACP coding-session state;
- lineage record;
- architecture documentation.

The remaining work is integration into existing agent/tool dispatch, config parsing, persisted SkillForge storage, and full E2E coverage.
