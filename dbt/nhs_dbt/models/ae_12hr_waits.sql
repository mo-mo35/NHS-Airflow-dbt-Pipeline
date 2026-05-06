select
    period,
    org_code,
    org_name,
    "patients_who_have_waited_12+_hrs_from_dta_to_admission" as waits_over_12hrs,
    "a&e_attendances_type_1" as type_1_attendances,
    round(
        100.0 * "patients_who_have_waited_12+_hrs_from_dta_to_admission"::float / nullif("a&e_attendances_type_1", 0),
        2
    ) as pct_12hr_waits
from {{ source('nhs', 'nhs_ae_raw') }}
where org_code is not null