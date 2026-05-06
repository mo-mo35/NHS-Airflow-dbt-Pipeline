from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.operators.bash import BashOperator
from datetime import datetime
import requests
import duckdb
import pandas as pd
import os

DATA_DIR = '/opt/airflow/data'
DB_PATH = '/opt/airflow/data/nhs.duckdb'

NHS_CSV_URL = 'https://www.england.nhs.uk/statistics/wp-content/uploads/sites/2/2026/04/March-2026-CSV-G49lw.csv'
def download_nhs_data():
    response = requests.get(NHS_CSV_URL)
    response.raise_for_status()
    filepath = os.path.join(DATA_DIR, 'nhs_ae_latest.csv')
    with open(filepath, 'wb') as f:
        f.write(response.content)
    print(f"Downloaded NHS A&E data to {filepath}")

def load_to_duckdb():
    filepath = os.path.join(DATA_DIR, 'nhs_ae_latest.csv')
    df = pd.read_csv(filepath, skiprows=0)
    df.columns = [c.strip().lower().replace(' ', '_').replace('-', '_') for c in df.columns]
    con = duckdb.connect(DB_PATH)
    con.execute("CREATE OR REPLACE TABLE nhs_ae_raw AS SELECT * FROM df")
    count = con.execute("SELECT COUNT(*) FROM nhs_ae_raw").fetchone()[0]
    print(f"Loaded {count} rows into DuckDB")
    con.close()

with DAG(
    dag_id='nhs_ae_pipeline',
    start_date=datetime(2026, 1, 1),
    schedule_interval='@monthly',
    catchup=False,
    tags=['nhs', 'healthcare']
) as dag:

    download = PythonOperator(
        task_id='download_nhs_data',
        python_callable=download_nhs_data
    )

    load = PythonOperator(
        task_id='load_to_duckdb',
        python_callable=load_to_duckdb
    )

    dbt_run = BashOperator(
    task_id='dbt_run',
    bash_command="""
        mkdir -p /home/airflow/.dbt && 
        cat > /home/airflow/.dbt/profiles.yml << 'EOF'
    nhs_dbt:
    target: dev
    outputs:
        dev:
        type: duckdb
        path: /opt/airflow/data/nhs.duckdb
    EOF
          cd /opt/airflow/dbt/nhs_dbt && dbt run && dbt test
      """,
    )
    download >> load >> dbt_run