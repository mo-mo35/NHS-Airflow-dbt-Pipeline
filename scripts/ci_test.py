#!/usr/bin/env python3
"""
Runs the actual load + dbt logic from run_pipeline.py against a small,
checked-in fixture instead of the live NHS site.

Why this exists: dbt run/test needs real data in nhs_ae_raw to check
anything meaningful. Hitting NHS England's site on every push would make CI
depend on an external, unversioned site being up and unchanged - exactly the
kind of flaky dependency a test shouldn't have. This fixture makes the test
deterministic and fast, while still exercising the same normalize/load/dbt
code path production uses (nothing here is reimplemented).
"""
import sys
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from run_pipeline import DB_PATH, load_to_duckdb, normalize_columns, run_dbt, write_dbt_profile

FIXTURE = Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "sample_ae_data.csv"


def main() -> None:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    df = normalize_columns(pd.read_csv(FIXTURE))
    load_to_duckdb(df)
    write_dbt_profile()
    run_dbt()
    print("CI dbt run + test passed against the fixture.")


if __name__ == "__main__":
    main()
