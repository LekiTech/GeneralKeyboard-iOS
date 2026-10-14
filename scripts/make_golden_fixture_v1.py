#!/usr/bin/env python3
"""Provenance for Tests/GeneralKeyboardTests/Fixtures/production-v1.sqlite.

Imported unchanged from the Lezgi/Avar engine (the fixture was copied
byte-for-byte; its SHA256 pin still holds).

RUN ONCE, 2026-07-29. THE FIXTURE IS FROZEN — DO NOT REGENERATE.

GoldenFixtureTests pins the fixture's SHA256; regenerating the file (even
with identical rows, SQLite does not guarantee identical bytes) breaks that
pin on purpose. If the fixture ever needs to change, that is a reviewed
decision: create a NEW fixture file with a new name and keep this one.

The point of the fixture is to be independent of the code under test. The
DDL and the seed markers below are copied VERBATIM from the released
LearnedWords.swift at commit b0c06d6 — the schema-version-1 implementation
users actually have — not built by the current schema builder or the
current test helpers, so a migration bug and a test-helper bug can never
cancel each other out.

The data covers every category the normalization migration must handle:

  ordinary rows                    хайи, зи, цӏийи, (зи хайи), (хайи цӏийи)
  Ukrainian і (U+0456)             чіукі      -> collides with чӏукӏ
  Latin l as palochka              кlвал      -> collides with кӏвал
  Latin homoglyphs a p x           кӏapax     -> кӏарах, no collision
  NFD (и + U+0306 breve)           йис        -> collides with NFC йис
  bigram with both sides broken    (чіукі кlвал) -> collides with (чӏукӏ кӏвал)
  bigram with an NFD side          (йис зи)     -> (йис зи), no collision

Every raw row passes the RELEASED isLearnable (lowercase, ≥2 letters, no
digits, no @ / .), so each one could genuinely have been written by the
schema-version-1 keyboard.
"""

import hashlib
import os
import sqlite3
import unicodedata

FIXTURE = os.path.join(os.path.dirname(__file__), "..",
                       "Tests", "GeneralKeyboardTests", "Fixtures", "production-v1.sqlite")

# Every defective token is built from explicit escapes so no editor,
# clipboard, or tool can silently normalize it into the canonical form.
NFD_YIS = "\u0438\u0306\u0438\u0441"              # NFD: и + COMBINING BREVE, ис
assert unicodedata.normalize("NFC", NFD_YIS) == "\u0439\u0438\u0441"
assert NFD_YIS.encode() != "\u0439\u0438\u0441".encode(), "must be byte-distinct"

UKRAINIAN = "\u0447\u0456\u0443\u043a\u0456"     # чіукі with Ukrainian і (U+0456)
LATIN_L = "\u043a\u006c\u0432\u0430\u043b"       # кlвал with ASCII l
HOMOGLYPHS = "\u043a\u04cf\u0061\u0070\u0061\u0078"  # кӏapax with ASCII a p a x

WORDS = [
    # (word, count, picked, last_used)
    ("хайи", 5, 2, 1_700_000_100),
    ("кӏвал", 3, 1, 1_700_000_200),      # canonical; кlвал merges into it
    ("зи", 9, 0, 1_700_000_050),
    (UKRAINIAN, 4, 1, 1_700_000_300),     # -> чӏукӏ (collision)
    ("чӏукӏ", 2, 1, 1_700_000_400),      # canonical twin, newer last_used
    (LATIN_L, 2, 1, 1_700_000_500),       # -> кӏвал (collision, newer last_used)
    (HOMOGLYPHS, 7, 0, 1_700_000_600),    # -> кӏарах (no collision)
    (NFD_YIS, 3, 0, 1_700_000_700),       # -> йис (collision)
    ("йис", 1, 1, 1_700_000_800),         # canonical twin, newer last_used
    ("цӏийи", 6, 3, 1_700_000_900),
]

BIGRAMS = [
    ("зи", "хайи", 4, 1_700_000_100),
    (UKRAINIAN, LATIN_L, 2, 1_700_000_300),   # -> (чӏукӏ, кӏвал), collision
    ("чӏукӏ", "кӏвал", 3, 1_700_000_400),
    ("хайи", "цӏийи", 2, 1_700_000_900),
    (NFD_YIS, "зи", 2, 1_700_000_700),         # -> (йис, зи), no collision
]


def main() -> None:
    os.makedirs(os.path.dirname(FIXTURE), exist_ok=True)
    if os.path.exists(FIXTURE):
        raise SystemExit(f"{FIXTURE} already exists — the fixture is frozen. "
                         "Create a new file under a new name instead.")

    con = sqlite3.connect(FIXTURE)
    con.execute("PRAGMA journal_mode=WAL")   # production databases are WAL
    # DDL verbatim from LearnedWords.swift @ b0c06d6.
    con.executescript("""
        CREATE TABLE IF NOT EXISTS meta(
            key TEXT PRIMARY KEY,
            value INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS user_word(
            word TEXT PRIMARY KEY,
            count INTEGER NOT NULL DEFAULT 0,
            picked INTEGER NOT NULL DEFAULT 0,
            last_used INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS user_bigram(
            prev TEXT NOT NULL,
            word TEXT NOT NULL,
            count INTEGER NOT NULL DEFAULT 0,
            last_used INTEGER NOT NULL,
            PRIMARY KEY(prev, word)
        );
        INSERT OR IGNORE INTO meta(key, value) VALUES('schema_version', 1);
        INSERT OR IGNORE INTO meta(key, value) VALUES('total_events', 0);
    """)
    # The two markers the released build wrote after its inline migrations.
    con.execute("INSERT OR REPLACE INTO meta(key, value) VALUES('filters_version', 1)")
    con.execute("INSERT OR REPLACE INTO meta(key, value) VALUES('palochka_fixed', 1)")
    # A believable event counter, as a released database would carry.
    con.execute("UPDATE meta SET value = 37 WHERE key = 'total_events'")

    con.executemany("INSERT INTO user_word VALUES(?, ?, ?, ?)", WORDS)
    con.executemany("INSERT INTO user_bigram VALUES(?, ?, ?, ?)", BIGRAMS)
    con.commit()
    # Fold the WAL into the main file so the fixture is one self-contained
    # file, exactly the shape of a database restored from a device backup
    # (sidecars are excluded from backups).
    con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    con.close()
    for suffix in ("-wal", "-shm"):
        try:
            os.remove(FIXTURE + suffix)
        except FileNotFoundError:
            pass

    digest = hashlib.sha256(open(FIXTURE, "rb").read()).hexdigest()
    print(f"frozen: {FIXTURE}")
    print(f"sha256: {digest}")


if __name__ == "__main__":
    main()
