-- Regression guard: NHS's export includes an England-wide "TOTAL" row
-- alongside real providers (found 2026-10-01). run_pipeline.py filters it
-- before loading, but this test fails loudly if that filter ever stops
-- catching it, rather than letting a bad row silently reappear.
select *
from {{ source('nhs', 'nhs_ae_raw') }}
where upper(trim(period)) = 'TOTAL'
