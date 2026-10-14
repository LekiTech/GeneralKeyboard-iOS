#!/usr/bin/env python3
"""Build the reference keyboard's small dictionary artifacts.

    python3 scripts/make_reference_artifacts.py \
        --words SOURCE_words.sqlite --bigrams SOURCE_bigrams.sqlite \
        --out DIR [--limit 5000]

Writes DIR/reference_words.sqlite and DIR/reference_bigrams.sqlite in the
artifact contract's shape (docs/engine/ARTIFACT_CONTRACT.md): the words table with
base_score, the bigrams table, and the meta table with artifact,
schema_version, content_version, normalization_version, min_reader_schema,
row_count and generated_at. The source is any artifact pair in the same
contract (the fixture data is Avar's, design decision 8). The output is
deterministic: the top LIMIT words by (base_score DESC, word), the bigram
rows whose suggested word is among them, sorted keys, a fixed timestamp,
4096-byte pages, VACUUMed.
"""
import argparse
import os
import sqlite3

GENERATED_AT = "2026-10-13T00:00:00Z"


def write_meta(con, kind, rows):
    con.execute("CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    for key, value in [("artifact", kind), ("schema_version", "1"), ("content_version", "1"),
                       ("normalization_version", "1"), ("min_reader_schema", "1"),
                       ("row_count", str(rows)), ("generated_at", GENERATED_AT)]:
        con.execute("INSERT INTO meta VALUES (?, ?)", (key, value))


def fresh(path):
    if os.path.exists(path):
        os.remove(path)
    con = sqlite3.connect(path)
    con.execute("PRAGMA page_size = 4096")
    con.execute("PRAGMA journal_mode = DELETE")
    return con


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--words", required=True)
    ap.add_argument("--bigrams", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--limit", type=int, default=5000)
    a = ap.parse_args()

    src = sqlite3.connect(f"file:{a.words}?mode=ro", uri=True)
    words = src.execute(
        "SELECT word, base_score FROM words ORDER BY base_score DESC, word LIMIT ?",
        (a.limit,)).fetchall()
    keep = {w for w, _ in words}
    src.close()
    srcb = sqlite3.connect(f"file:{a.bigrams}?mode=ro", uri=True)
    pairs = [r for r in srcb.execute("SELECT prev, word, weight FROM bigrams ORDER BY prev, word")
             if r[1] in keep]
    srcb.close()

    os.makedirs(a.out, exist_ok=True)
    con = fresh(os.path.join(a.out, "reference_words.sqlite"))
    con.execute("CREATE TABLE words(word TEXT PRIMARY KEY, base_score INTEGER NOT NULL DEFAULT 0)"
                " WITHOUT ROWID")
    con.executemany("INSERT INTO words VALUES (?, ?)", sorted(words))
    write_meta(con, "reference_words", len(words))
    con.commit(); con.execute("VACUUM"); con.close()

    con = fresh(os.path.join(a.out, "reference_bigrams.sqlite"))
    con.execute("CREATE TABLE bigrams(prev TEXT NOT NULL, word TEXT NOT NULL, weight INTEGER NOT NULL,"
                " PRIMARY KEY(prev, word)) WITHOUT ROWID")
    con.executemany("INSERT INTO bigrams VALUES (?, ?, ?)", pairs)
    write_meta(con, "reference_bigrams", len(pairs))
    con.commit(); con.execute("VACUUM"); con.close()
    print(f"reference_words: {len(words)} rows, reference_bigrams: {len(pairs)} rows")


if __name__ == "__main__":
    main()
