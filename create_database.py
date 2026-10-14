from pathlib import Path
import sqlite3

# Individua la cartella del progetto a partire da questo script.
PROJECT_ROOT = Path(__file__).resolve().parents[1]
DB_PATH = PROJECT_ROOT / "data" / "database" / "inflation.sqlite"

DB_PATH.parent.mkdir(parents=True, exist_ok=True)

with sqlite3.connect(DB_PATH) as conn:
    conn.execute("PRAGMA foreign_keys = ON")

    conn.executescript("""
        CREATE TABLE IF NOT EXISTS series (
            series_id      TEXT PRIMARY KEY,
            series_key     TEXT NOT NULL UNIQUE,
            description    TEXT NOT NULL,
            source         TEXT NOT NULL,
            geography      TEXT NOT NULL,
            unit           TEXT NOT NULL,
            adjustment     TEXT NOT NULL,
            downloaded_at  TEXT NOT NULL,
            raw_file       TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS observations (
            series_id  TEXT NOT NULL,
            period     TEXT NOT NULL,
            value      REAL,
            status     TEXT,

            PRIMARY KEY (series_id, period),

            FOREIGN KEY (series_id)
                REFERENCES series(series_id)
        );
    """)

print(f"Database pronto: {DB_PATH}")
