# ADR-007: Hardware tiers and resource policy
Status: Proposed
Decision: Detect chip/RAM at launch -> tier8/tier16/tier32+. One heavy model resident by default, LRU + memory-pressure unload, thermal/battery throttling, event-driven (no polling) idle behaviour. Optional XPC isolation of engines if crashes observed.
Verification: serial benchmarks on M3 Pro 18 GB recorded in specs/research/benchmarks.md; M1/8 GB extrapolated until real hardware available.
