{{ config(materialized='view') }}
-- =============================================================================
-- Port of: the ORDERUSERS CTE inside ORDERCHARGES_WITHADJUSTMENT_VW
--
-- Pivots ORDERUSER rows into one column per role. Role GUIDs are in
-- dbt_project.yml vars so they are documented rather than magic.
--
-- Note the hardcoded name fix for 'JORGE LOPEZ'. It is applied twice in the
-- original view (here and again in the final select). Kept for fidelity - but
-- it belongs in a seed/mapping table, not in SQL. See TODO.
-- =============================================================================

with pivoted as (
    select
        o.id as orderguid,
        max(case when ou.roleid = '{{ var("role_sales_rep_id") }}'
                 then upper(u.realname) end)                        as salesrepuser,
        coalesce(max(case when ou.roleid = '{{ var("role_spot_bid_lead_id") }}'
                 then upper(u.realname) end), 'NONE')               as spotbidlead,
        coalesce(max(case when ou.roleid = '{{ var("role_account_manager_id") }}'
                 then upper(u.realname) end), 'NONE')               as accountmanager,
        coalesce(max(case when ou.roleid = '{{ var("role_csr_id") }}'
                 then upper(u.realname) end), 'NONE')               as csr
    from {{ source('probillsvc', 'order') }} o
    left join {{ source('probillsvc', 'orderuser') }} ou
           on ou.orderid = o.id and ou.isrowdeleted = 0
    left join {{ source('usersvc', 'user') }} u
           on u.id = ou.userid
    where o.isrowdeleted = 0
    group by o.id
)

select
    orderguid,
    salesrepuser,
    -- TODO: move this alias fix into a seed (seeds/sales_rep_aliases.csv)
    case when salesrepuser ilike 'JORGE LOPEZ'
         then 'JORGE BENJAMIN LOPEZ SOLORZANO'
         else salesrepuser end as salesrep,
    spotbidlead,
    accountmanager,
    csr
from pivoted
