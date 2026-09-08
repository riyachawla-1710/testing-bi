{{ config(materialized='view') }}
-- =============================================================================
-- Port of: BI.ANALYTICS.TONUORDERSBI_VW
--
-- TONU = "truck ordered, not used". Orders whose probills have NO trip events
-- at all, i.e. nothing ever moved. Used as an exclusion list: the Labatt
-- revenue allocation and the predicted-revenue cascade both drop these.
--
-- Small and fully portable - reads only Postgres.
-- =============================================================================

select orderid, totalevent
from (
    select
        pb.orderid,
        count(te.id) as totalevent
    from {{ source('probillsvc', 'probill') }} pb
    left join {{ source('tripsvc', 'tripevent') }} te
           on pb.id = te.probillid
          and te.isrowdeleted = false
    where pb.isrowdeleted = false
    group by pb.orderid
) a
where a.totalevent = 0
