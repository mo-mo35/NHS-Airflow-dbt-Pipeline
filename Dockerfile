# Standalone image for the scheduled Fargate task - no Airflow here, that
# stays local-only in docker-compose.yml. Versions pinned against current
# PyPI releases for a reproducible build.
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY dbt/nhs_dbt ./dbt/nhs_dbt
COPY run_pipeline.py ./run_pipeline.py

CMD ["python", "run_pipeline.py"]
