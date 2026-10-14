#!/usr/bin/env python3
"""Measures what VACUUM actually buys at the learned store's caps.

Reproduces the production schema and the exact maintenance sequence from
LearnedWords.maintain(): decay halves every counter every 2000 events,
prune trims to 5000 words / 10000 bigrams, then VACUUM.

Runs three regimes over the same synthetic workload:
  A  never VACUUM
  B  VACUUM after each decay (production today)
  C  auto_vacuum=INCREMENTAL + incremental_vacuum after each decay
"""
import os, random, sqlite3, tempfile, time

WORDS, BIGRAMS = 5000, 10000
DECAY_EVERY, PRUNE_EVERY = 2000, 200
CYCLES = 6                      # 6 decay passes = 12 000 learn events
random.seed(17)

ALPHABET = "абвгдежзийклмнопрстуфхцчшыэюя"

def word(i):
    random.seed(i)
    return "".join(random.choice(ALPHABET) for _ in range(random.randint(4, 9)))

def build(path, auto_vacuum):
    con = sqlite3.connect(path)
    if auto_vacuum:
        con.execute("PRAGMA auto_vacuum=INCREMENTAL")
    con.execute("PRAGMA journal_mode=WAL")
    con.executescript("""
        CREATE TABLE meta(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
        CREATE TABLE user_word(word TEXT PRIMARY KEY, count INTEGER NOT NULL DEFAULT 0,
                               picked INTEGER NOT NULL DEFAULT 0, last_used INTEGER NOT NULL);
        CREATE TABLE user_bigram(prev TEXT NOT NULL, word TEXT NOT NULL,
                                 count INTEGER NOT NULL DEFAULT 0, last_used INTEGER NOT NULL,
                                 PRIMARY KEY(prev, word));
        INSERT INTO meta VALUES('total_events', 0);
    """)
    return con

def fill(con, n_words, n_pairs, now):
    con.executemany("INSERT OR REPLACE INTO user_word VALUES(?,?,?,?)",
                    [(word(i), random.randint(1, 20), random.randint(0, 5), now) for i in range(n_words)])
    con.executemany("INSERT OR REPLACE INTO user_bigram VALUES(?,?,?,?)",
                    [(word(i), word(i + 1), random.randint(1, 10), now) for i in range(n_pairs)])
    con.commit()

def prune(con):
    excess = con.execute("SELECT COUNT(*) FROM user_word").fetchone()[0] - WORDS
    if excess > 0:
        con.execute(f"""DELETE FROM user_word WHERE word IN (
            SELECT word FROM user_word ORDER BY count + 3*picked ASC, last_used ASC LIMIT {excess})""")
    excess = con.execute("SELECT COUNT(*) FROM user_bigram").fetchone()[0] - BIGRAMS
    if excess > 0:
        con.execute(f"""DELETE FROM user_bigram WHERE rowid IN (
            SELECT rowid FROM user_bigram ORDER BY count ASC, last_used ASC LIMIT {excess})""")
    con.commit()

def decay(con):
    con.execute("UPDATE user_word SET count = count/2, picked = picked/2")
    con.execute("DELETE FROM user_word WHERE count + picked = 0")
    con.execute("UPDATE user_bigram SET count = count/2")
    con.execute("DELETE FROM user_bigram WHERE count = 0")
    con.commit()

def size(path):
    total = os.path.getsize(path)
    for suffix in ("-wal", "-shm"):
        if os.path.exists(path + suffix):
            total += os.path.getsize(path + suffix)
    return total

def run(regime):
    d = tempfile.mkdtemp()
    path = os.path.join(d, "learned.sqlite")
    con = build(path, auto_vacuum=(regime == "C"))
    now = int(time.time())
    fill(con, WORDS, BIGRAMS, now)
    con.commit()

    peak_ms, sizes = 0.0, []
    for cycle in range(CYCLES):
        # a decay window's worth of churn: new words arrive, caps are exceeded
        fill(con, WORDS + 1200, BIGRAMS + 2500, now)
        for _ in range(DECAY_EVERY // PRUNE_EVERY):
            prune(con)
        decay(con)
        prune(con)
        t0 = time.perf_counter()
        if regime == "B":
            con.execute("VACUUM")
        elif regime == "C":
            con.execute("PRAGMA incremental_vacuum")
        ms = (time.perf_counter() - t0) * 1000
        peak_ms = max(peak_ms, ms)
        con.commit()
        sizes.append(size(path))

    free = con.execute("PRAGMA freelist_count").fetchone()[0]
    page = con.execute("PRAGMA page_size").fetchone()[0]
    rows = (con.execute("SELECT COUNT(*) FROM user_word").fetchone()[0],
            con.execute("SELECT COUNT(*) FROM user_bigram").fetchone()[0])
    con.close()
    return {"regime": regime, "final_kb": sizes[-1] / 1024, "max_kb": max(sizes) / 1024,
            "peak_ms": peak_ms, "free_pages": free, "free_kb": free * page / 1024, "rows": rows}

print(f"{'regime':<8}{'final KB':>10}{'peak KB':>10}{'maint ms':>10}{'free pages':>12}{'free KB':>9}  rows")
for regime in ("A", "B", "C"):
    r = run(regime)
    label = {"A": "no vac", "B": "VACUUM", "C": "incr"}[regime]
    print(f"{label:<8}{r['final_kb']:>10.0f}{r['max_kb']:>10.0f}{r['peak_ms']:>10.1f}"
          f"{r['free_pages']:>12}{r['free_kb']:>9.0f}  {r['rows']}")
