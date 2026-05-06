select
    period,
    org_code,
    org_name,
    "a&e_attendances_type_1" as type_1_attendances,
    "attendances_over_4hrs_type_1" as over_4hrs_type_1,
    round(
        100.0 * (1 - "attendances_over_4hrs_type_1"::float / nullif("a&e_attendances_type_1", 0)),
        1
    ) as pct_within_4hrs
from {{ source('nhs', 'nhs_ae_raw') }}
where org_code is not null
and "a&e_attendances_type_1" > 0