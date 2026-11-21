# ADR-001: Persistence — GRDB (SQLite + FTS5) over SwiftData
Status: Proposed
Context: Full-text search across 5,000+ transcripts incl. Sinhala; soft delete; incremental segment writes; list load <500 ms; migrations.
Decision: GRDB with WAL, DatabaseMigrator, FTS5 virtual table synced to segments.
Rationale: SwiftData has no FTS5 and weaker control over indexing/migrations/perf; GRDB is mature, Swift 6 compatible, actor-friendly.
Consequences: Own repository layer; spot-check FTS5 tokenization on Sinhala (unicode61 vs custom) in Persistence tests.
