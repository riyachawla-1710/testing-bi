
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
        max(case when ou.roleid = '588C2A53-736C-491A-B1C7-3EF0B29ACFB3'
                 then upper(u.realname) end)                        as salesrepuser,
        coalesce(max(case when ou.roleid = 'DF39571B-5254-4210-B17E-277280B06822'
                 then upper(u.realname) end), 'NONE')               as spotbidlead,
        coalesce(max(case when ou.roleid = '73661DC2-A21A-4987-8AFC-C3203B313639'
                 then upper(u.realname) end), 'NONE')               as accountmanager,
        coalesce(max(case when ou.roleid = '38AB7753-8F16-4D24-97E7-EBBCAEFD354F'
                 then upper(u.realname) end), 'NONE')               as csr
    from "test"."probillsvc"."order" o
    left join "test"."probillsvc".orderuser ou
           on ou.orderid = o.id and ou.isrowdeleted = false
    left join "test"."usersvc"."user" u
           on u.id = ou.userid
    where o.isrowdeleted = false
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