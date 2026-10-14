from pathlib import Path
from datetime import date
import sqlite3

import pandas as pd


PROJECT_ROOT = Path(__file__).resolve().parents[1]
RAW_DIR = PROJECT_ROOT / "data" / "raw"
DB_PATH = PROJECT_ROOT / "data" / "database" / "inflation.sqlite"

# Inserisci la data effettiva in cui hai scaricato i quattro file.
DOWNLOAD_DATE = input("Data del download (YYYY-MM-DD): ").strip()
date.fromisoformat(DOWNLOAD_DATE)  # Controlla che sia una data valida.

SERIES = [
    {
        "id": "euribor_3m",
        "file": "euribor_3_month.csv",
        "key": "FM.M.U2.EUR.RT.MM.EURIBOR3MD_.HSTA",
        "description": "Euribor a tre mesi, media mensile",
        "source": "ECB Data Portal / Financial providers",
        "geography": "Euro area monetary market",
        "unit": "Percent per annum",
        "adjustment": "Monthly average",
    },
    {
        "id": "hicp_energy",
        "file": "hicp_inflation_rate_energy.csv",
        "key": "HICP.M.U2.N.NRGY00.4D0.INX",
        "description": "HICP energia, indice",
        "source": "Eurostat via ECB Data Portal",
        "geography": "Euro area, changing composition",
        "unit": "Index, 2025=100",
        "adjustment": "Neither seasonally nor working day adjusted",
    },
    {
        "id": "hicp_total",
        "file": "hicp_inflation_rate_total.csv",
        "key": "HICP.M.U2.N.000000.4D0.INX",
        "description": "HICP complessivo, indice",
        "source": "Eurostat via ECB Data Portal",
        "geography": "Euro area, changing composition",
        "unit": "Index, 2025=100",
        "adjustment": "Neither seasonally nor working day adjusted",
    },
    {
        "id": "industrial_production",
        "file": "total_industrial_production.csv",
        "key": "STBS.M.I9.Y.PROD.NS0020.4D0.N.IX",
        "description": "Produzione industriale, escluse costruzioni",
        "source": "Eurostat via ECB Data Portal",
        "geography": "Euro area 20, fixed composition",
        "unit": "Index",
        "adjustment": "Working day and seasonally adjusted",
    },
]


def read_observations(spec):
    """Legge e controlla un CSV, senza modificare il file originale."""
    df = pd.read_csv(RAW_DIR / spec["file"])

    if list(df.columns[:2]) != ["DATE", "TIME PERIOD"] or len(df.columns) != 3:
        raise ValueError(f"Struttura inattesa: {spec['file']}")

    value_column = df.columns[2]

    if f"({spec['key']})" not in value_column:
        raise ValueError(f"Codice della serie inatteso: {spec['file']}")

    periods = pd.to_datetime(
        df["DATE"], format="%Y-%m-%d", errors="raise"
    ).dt.to_period("M")

    if periods.isna().any():
        raise ValueError(f"Date mancanti: {spec['file']}")

    selected = periods.between("2000-01", "2025-12")

    observations = pd.DataFrame({
        "period": periods.loc[selected].astype(str),
        "value": pd.to_numeric(
            df.loc[selected, value_column], errors="raise"
        ),
    }).sort_values("period")

    if observations.empty:
        raise ValueError(f"Nessun dato nel periodo richiesto: {spec['file']}")

    if observations["period"].duplicated().any():
        raise ValueError(f"Mesi duplicati: {spec['file']}")

    expected = pd.period_range("2000-01", "2025-12", freq="M").astype(str)
    absent = sorted(set(expected) - set(observations["period"]))

    print(
        f"{spec['id']}: "
        f"{len(observations)} righe, "
        f"{observations['value'].isna().sum()} valori mancanti, "
        f"{len(absent)} mesi assenti"
    )

    if absent:
        print("Mesi assenti:", ", ".join(absent))

    return observations


# Legge tutti i file prima di iniziare a scrivere nel database.
datasets = [(spec, read_observations(spec)) for spec in SERIES]

if not DB_PATH.exists():
    raise FileNotFoundError("Esegui prima scripts/create_database.py")

conn = sqlite3.connect(DB_PATH)

try:
    conn.execute("PRAGMA foreign_keys = ON")

    # Tutti gli inserimenti riescono, oppure vengono annullati insieme.
    with conn:
        for spec, observations in datasets:
            conn.execute(
                """
                INSERT INTO series (
                    series_id, series_key, description, source,
                    geography, unit, adjustment, downloaded_at, raw_file
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    spec["id"],
                    spec["key"],
                    spec["description"],
                    spec["source"],
                    spec["geography"],
                    spec["unit"],
                    spec["adjustment"],
                    DOWNLOAD_DATE,
                    f"data/raw/{spec['file']}",
                ),
            )

            rows = [
                (
                    spec["id"],
                    period,
                    None if pd.isna(value) else float(value),
                    None,
                )
                for period, value in observations.itertuples(
                    index=False, name=None
                )
            ]

            conn.executemany(
                """
                INSERT INTO observations (
                    series_id, period, value, status
                )
                VALUES (?, ?, ?, ?)
                """,
                rows,
            )
finally:
    conn.close()

print("Importazione completata.")
