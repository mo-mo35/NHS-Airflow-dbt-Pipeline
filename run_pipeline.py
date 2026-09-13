#!/usr/bin/env python3
"""
NHS A&E pipeline entrypoint for the scheduled Fargate task.

Replaces the Airflow DAG's three tasks (download / load / dbt run+test) with
a single container-native run: no Airflow, no bash heredoc, no hardcoded
monthly URL. DuckDB's warehouse file is round-tripped through S3 since a
Fargate task has no persistent disk between runs.

Fixes carried over from the DAG review:
  - CSV URL is discovered from NHS England's stats page instead of hardcoded,
    since the real URL changes every month and isn't computable from a date.
  - Loads are an upsert scoped to the period(s) in the new file, not
    CREATE OR REPLACE, so history actually accumulates across monthly runs.
  - dbt run/test failures propagate as a non-zero process exit, so a failed
    run shows as a FAILED ECS task - not a silent green checkmark.
"""
import datetime
import io
import os
import re
import subprocess
import sys
from pathlib import Path

import boto3
import duckdb
import pandas as pd
import requests
from bs4 import BeautifulSoup
from botocore.exceptions import ClientError

DATA_DIR = Path("/app/data")
DB_PATH = DATA_DIR / "nhs.duckdb"
DBT_PROJECT_DIR = Path("/app/dbt/nhs_dbt")
PROFILES_DIR = Path("/root/.dbt")

S3_DB_KEY = "warehouse/nhs.duckdb"


def _s3_bucket() -> str:
    # Looked up lazily (not at import time) so this module can be imported -
    # e.g. by the CI test script - without S3_BUCKET being set at all.
    return os.environ["S3_BUCKET"]

STATS_BASE = "https://www.england.nhs.uk/statistics/statistical-work-areas/ae-waiting-times-and-activity"
CSV_LINK_PATTERN = re.compile(r"Monthly A&E .*\(CSV", re.IGNORECASE)


def current_fiscal_year_slug(today: datetime.date | None = None) -> str:
    """NHS stats pages are grouped by UK fiscal year (April-March), e.g. '2026-27'."""
    today = today or datetime.date.today()
    fy_start = today.year if today.month >= 4 else today.year - 1
    return f"{fy_start}-{str(fy_start + 1)[-2:]}"


def find_latest_csv_link(fy_slug: str) -> tuple[str | None, str | None]:
    url = f"{STATS_BASE}/ae-attendances-and-emergency-admissions-{fy_slug}/"
    resp = requests.get(url, timeout=30)
    resp.raise_for_status()
    soup = BeautifulSoup(resp.text, "html.parser")
    for a in soup.find_all("a", href=True):
        if CSV_LINK_PATTERN.search(a.get_text(strip=True)):
            return a["href"], a.get_text(strip=True)
    return None, None


def discover_current_csv_url() -> str:
    """NHS lists months newest-first, so the first CSV link on the page is
    always whatever's most recently published - no need to guess which
    month is 'due' given their ~6 week publication lag."""
    fy_slug = current_fiscal_year_slug()
    href, label = find_latest_csv_link(fy_slug)

    if href is None:
        # Early in a new fiscal year the page may not be populated yet.
        prev_start = int(fy_slug.split("-")[0]) - 1
        fy_slug = f"{prev_start}-{str(prev_start + 1)[-2:]}"
        href, label = find_latest_csv_link(fy_slug)

    if href is None:
        raise RuntimeError(f"No 'Monthly A&E ... (CSV' link found for fiscal year {fy_slug}")

    print(f"Discovered latest release: {label} -> {href}")
    return href


def normalize_columns(df: pd.DataFrame) -> pd.DataFrame:
    df.columns = [c.strip().lower().replace(" ", "_").replace("-", "_") for c in df.columns]
    return df


def download_csv(url: str) -> pd.DataFrame:
    resp = requests.get(url, timeout=60)
    resp.raise_for_status()
    return normalize_columns(pd.read_csv(io.BytesIO(resp.content)))


def sync_db_from_s3(s3) -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    bucket = _s3_bucket()
    try:
        s3.download_file(bucket, S3_DB_KEY, str(DB_PATH))
        print(f"Restored existing warehouse from s3://{bucket}/{S3_DB_KEY}")
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code")
        if code in ("404", "NoSuchKey"):
            print("No existing warehouse in S3 - starting fresh (first run)")
        else:
            raise


def load_to_duckdb(df: pd.DataFrame) -> None:
    if "period" not in df.columns:
        raise RuntimeError("Expected a 'period' column in the NHS extract - schema may have changed")
    periods = df["period"].unique().tolist()

    con = duckdb.connect(str(DB_PATH))
    con.register("df_new", df)
    con.execute("CREATE TABLE IF NOT EXISTS nhs_ae_raw AS SELECT * FROM df_new LIMIT 0")

    placeholders = ",".join(["?"] * len(periods))
    con.execute(f"DELETE FROM nhs_ae_raw WHERE period IN ({placeholders})", periods)
    con.execute("INSERT INTO nhs_ae_raw SELECT * FROM df_new")

    count = con.execute("SELECT COUNT(*) FROM nhs_ae_raw").fetchone()[0]
    print(f"Upserted period(s) {periods} - {count} total rows now in nhs_ae_raw")
    con.close()


def write_dbt_profile() -> None:
    PROFILES_DIR.mkdir(parents=True, exist_ok=True)
    (PROFILES_DIR / "profiles.yml").write_text(
        f"""\
nhs_dbt:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: {DB_PATH}
"""
    )


def run_dbt() -> None:
    # check=True -> CalledProcessError on a non-zero exit, which main() lets
    # propagate into a non-zero process exit. That's what makes a failing
    # dbt test show up as a FAILED task in ECS instead of disappearing.
    subprocess.run(["dbt", "run"], cwd=DBT_PROJECT_DIR, check=True)
    subprocess.run(["dbt", "test"], cwd=DBT_PROJECT_DIR, check=True)


def sync_db_to_s3(s3) -> None:
    bucket = _s3_bucket()
    s3.upload_file(str(DB_PATH), bucket, S3_DB_KEY)
    print(f"Persisted warehouse to s3://{bucket}/{S3_DB_KEY}")


def main() -> None:
    s3 = boto3.client("s3")
    sync_db_from_s3(s3)

    csv_url = discover_current_csv_url()
    df = download_csv(csv_url)
    load_to_duckdb(df)

    write_dbt_profile()
    run_dbt()

    sync_db_to_s3(s3)
    print("Pipeline run complete.")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"Pipeline run FAILED: {exc}", file=sys.stderr)
        sys.exit(1)
