select
    period,
    org_code,
    org_name,
    parent_org,
    "a&e_attendances_type_1" as type_1_attendances,
    "a&e_attendances_type_2" as type_2_attendances,
    "a&e_attendances_other_a&e_department" as other_attendances,
    "a&e_attendances_type_1" + "a&e_attendances_type_2" + "a&e_attendances_other_a&e_department" as total_attendances
from {{ source('nhs', 'nhs_ae_raw') }}
where org_code is not null