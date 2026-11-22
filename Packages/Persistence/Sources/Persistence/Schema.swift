// swiftlint:disable function_body_length
import AppCore
import Foundation
import GRDB

/// Characters that FTS5's `unicode61` tokenizer must treat as part of a word so Sinhala is searchable.
///
/// `unicode61` only treats categories L*, N* and Co as token characters, so Sinhala vowel signs (Mn/Mc) and the
/// zero-width joiner used in conjuncts (U+200D) would split words apart. Adding the whole Sinhala block
/// (U+0D80...U+0DFF) plus ZWJ keeps each Sinhala word a single token.
enum FTSConfig {
    static let tokenCharacters: Set<Character> = {
        var set = Set<Character>()
        for value in 0x0D80...0x0DFF {
            if let scalar = Unicode.Scalar(value) { set.insert(Character(scalar)) }
        }
        set.insert(Character("\u{200D}"))
        return set
    }()
}

enum Schema {
    /// Builds the migrator. Migrations are append-only; never edit a shipped one.
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-initial") { db in
            try createLibraryTables(db)
            try createAuxiliaryTables(db)
            try createSearchIndex(db)
        }
        // SCR-010: IGN-AC-05 needs to know which ignore flags the user set by hand.
        migrator.registerMigration("v2-segment-manual-ignore") { db in
            try db.execute(sql: "ALTER TABLE segment ADD COLUMN ignoreFlagIsManual INTEGER NOT NULL DEFAULT 0")
        }
        return migrator
    }

    private static func createLibraryTables(_ db: GRDB.Database) throws {
        try db.execute(
            sql: """
                CREATE TABLE transcript (
                  id TEXT PRIMARY KEY NOT NULL,
                  title TEXT NOT NULL,
                  source TEXT NOT NULL,
                  duration DOUBLE NOT NULL DEFAULT 0,
                  languages TEXT NOT NULL DEFAULT '[]',
                  speakers TEXT NOT NULL DEFAULT '[]',
                  tags TEXT NOT NULL DEFAULT '[]',
                  folderID TEXT,
                  mediaAssetID TEXT,
                  meetingID TEXT,
                  revisionOf TEXT,
                  createdAt DOUBLE NOT NULL,
                  modifiedAt DOUBLE NOT NULL,
                  deletedAt DOUBLE
                );
                CREATE INDEX transcript_created ON transcript(deletedAt, createdAt);
                CREATE INDEX transcript_modified ON transcript(deletedAt, modifiedAt);
                CREATE INDEX transcript_folder ON transcript(folderID);
                CREATE INDEX transcript_revision ON transcript(revisionOf);

                CREATE TABLE segment (
                  id TEXT PRIMARY KEY NOT NULL,
                  transcriptID TEXT NOT NULL REFERENCES transcript(id) ON DELETE CASCADE,
                  start DOUBLE NOT NULL,
                  "end" DOUBLE NOT NULL,
                  text TEXT NOT NULL,
                  speakerID TEXT,
                  languageCode TEXT,
                  languageConfidence DOUBLE,
                  confidence DOUBLE,
                  noSpeechProbability DOUBLE,
                  isIgnored INTEGER NOT NULL DEFAULT 0,
                  words BLOB,
                  translations TEXT
                );
                CREATE INDEX segment_transcript ON segment(transcriptID, start);

                CREATE TABLE bookmark (
                  id TEXT PRIMARY KEY NOT NULL,
                  transcriptID TEXT NOT NULL REFERENCES transcript(id) ON DELETE CASCADE,
                  time DOUBLE NOT NULL,
                  note TEXT NOT NULL DEFAULT '',
                  createdAt DOUBLE NOT NULL,
                  deletedAt DOUBLE
                );
                CREATE INDEX bookmark_transcript ON bookmark(transcriptID, time);

                """)
    }

    private static func createAuxiliaryTables(_ db: GRDB.Database) throws {
        try db.execute(
            sql: """
                CREATE TABLE mediaAsset (
                  id TEXT PRIMARY KEY NOT NULL,
                  kind TEXT NOT NULL,
                  bookmark BLOB,
                  libraryRelativePath TEXT,
                  duration DOUBLE NOT NULL DEFAULT 0,
                  isOwnedByLibrary INTEGER NOT NULL DEFAULT 0,
                  deletedAt DOUBLE
                );

                """)
        try db.execute(
            sql: """
                CREATE TABLE job (
                  id TEXT PRIMARY KEY NOT NULL,
                  priority INTEGER NOT NULL DEFAULT 0,
                  createdAt DOUBLE NOT NULL,
                  deletedAt DOUBLE,
                  payload BLOB NOT NULL
                );

                CREATE TABLE ignoreRule (
                  id TEXT PRIMARY KEY NOT NULL,
                  pattern TEXT NOT NULL,
                  match TEXT NOT NULL,
                  scope TEXT NOT NULL,
                  isEnabled INTEGER NOT NULL,
                  isHallucinationRule INTEGER NOT NULL,
                  deletedAt DOUBLE
                );

                CREATE TABLE replacementRule (
                  id TEXT PRIMARY KEY NOT NULL,
                  find TEXT NOT NULL,
                  replacement TEXT NOT NULL,
                  matchCase INTEGER NOT NULL,
                  wholeWord INTEGER NOT NULL,
                  isRegex INTEGER NOT NULL,
                  isEnabled INTEGER NOT NULL,
                  deletedAt DOUBLE
                );

                """)
        try db.execute(
            sql: """
                CREATE TABLE captionPreset (
                  id TEXT PRIMARY KEY NOT NULL,
                  name TEXT NOT NULL,
                  payload BLOB NOT NULL,
                  deletedAt DOUBLE
                );

                CREATE TABLE exportPreset (
                  id TEXT PRIMARY KEY NOT NULL,
                  name TEXT NOT NULL,
                  payload BLOB NOT NULL,
                  deletedAt DOUBLE
                );

                CREATE TABLE voiceProfile (
                  id TEXT PRIMARY KEY NOT NULL,
                  name TEXT NOT NULL,
                  createdAt DOUBLE NOT NULL,
                  payload BLOB NOT NULL,
                  deletedAt DOUBLE
                );

                CREATE TABLE meeting (
                  id TEXT PRIMARY KEY NOT NULL,
                  startedAt DOUBLE NOT NULL,
                  transcriptID TEXT,
                  payload BLOB NOT NULL,
                  deletedAt DOUBLE
                );
                CREATE INDEX meeting_started ON meeting(startedAt);

                CREATE TABLE dictationEntry (
                  id TEXT PRIMARY KEY NOT NULL,
                  text TEXT NOT NULL,
                  language TEXT,
                  createdAt DOUBLE NOT NULL,
                  deletedAt DOUBLE
                );
                CREATE INDEX dictation_created ON dictationEntry(createdAt);

                CREATE TABLE setting (
                  key TEXT PRIMARY KEY NOT NULL,
                  value BLOB NOT NULL
                );
                """)
    }

    private static func createSearchIndex(_ db: GRDB.Database) throws {
        try db.create(virtualTable: "segmentFTS", using: FTS5()) { t in
            t.synchronize(withTable: "segment")
            t.tokenizer = .unicode61(diacritics: .remove, categories: "", tokenCharacters: FTSConfig.tokenCharacters)
            t.column("text")
        }
    }
}
// swiftlint:enable function_body_length
