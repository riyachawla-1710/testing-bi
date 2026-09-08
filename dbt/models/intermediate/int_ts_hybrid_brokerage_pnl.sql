{{ config(materialized='table') }}
-- =============================================================================
-- Port of: BI.ANALYTICS.TSHYBRIDBROKERAGEPANDL_VW
--
-- Brokerage cost and gross-profit per order. Only needed for the
-- "Revenue Execution Analysis" dashboards (Asset vs Brokerage split and
-- Brokerage GP%), NOT for "Revenue Performance Analysis".
--
-- Depends on BI.ANALYTICS.GLOBALBROKERAGEANALYSIS, which is not ported yet
-- (17,596 chars, its own scope). Declared as a source so the DAG is honest.
--
-- HARDCODED COST RATES ------------------------------------------------------
-- Trailer and transfer costs are literal dollar amounts baked into the SQL:
--   trailer, TS-hybrid leg   : reefer/heated 400 USD / 550 CAD, else 200 / 275
--   trailer, otherwise       : reefer/heated 250 USD / 300 CAD, else 120 / 150
--   transfer trip            : 150 USD / 200 CAD
-- These belong in a seed file so finance can change them without a code change.
-- See seeds/brokerage_cost_rates.csv (TODO).
--
-- POSTGRES PORT NOTES:
--   * IFF / ZEROIFNULL / IFNULL / LISTAGG -> case / coalesce / string_agg (done)
--   * `x ILIKE ANY (...)` -> Postgres supports ILIKE ANY (ARRAY[...])   (done)
--   * GROUP BY ALL -> explicit list (done)
--   * Snowflake allows reusing a select alias later in the same SELECT.
--     Postgres does not, so the aliased expressions are split into CTEs below.
-- =============================================================================

with orders_in_contract as (
    select
        contractguid,
        count(distinct orderguid)                          as oic,
        chargescost_usd / count(distinct orderguid)        as contractcostusd,
        chargescost_cad / count(distinct orderguid)        as contractcostcad
    from {{ source('pending', 'globalbrokerageanalysis') }}
    where orderguid is not null
    group by contractguid, chargescost_usd, chargescost_cad
),

has_trailer as (
    select distinct orderid as orderguid
    from {{ source('probillsvc', 'probill') }}
    where trailerid is not null
),

-- Step 1: everything that does not depend on another alias
brokerage_raw as (
    select
        gb.orderguid,
        gb.order_currency                                  as currency,
        gb.orderno,
        gb.delivereddate,
        string_agg(distinct gb.dispatcher, ', ')           as dispatcher,
        count(distinct gb.contractguid)                    as cio,

        gb.orderrevenue_usd + gb.totalmanualrevenue_usd    as orderrevenueusd,
        gb.orderrevenue_cad + gb.totalmanualrevenue_cad    as orderrevenuecad,

        (gb.tripcount = 0)                                 as purebrokerage,
        (gb.tripcount > 0 and gb.nonmexicotripcount = 0)   as tshybridbrokerage,

        case when ht.orderguid is not null then
            case when gb.tripcount > 0 and gb.nonmexicotripcount = 0
                 then case when gb.equipmenttype ilike any ('%REEF%', '%HEAT%') then 400 else 200 end
                 else case when gb.equipmenttype ilike any ('%REEF%', '%HEAT%') then 250 else 120 end
            end
        else 0 end                                         as trailercostusd,

        case when ht.orderguid is not null then
            case when gb.tripcount > 0 and gb.nonmexicotripcount = 0
                 then case when gb.equipmenttype ilike any ('%REEF%', '%HEAT%') then 550 else 275 end
                 else case when gb.equipmenttype ilike any ('%REEF%', '%HEAT%') then 300 else 150 end
            end
        else 0 end                                         as trailercostcad,

        case when gb.tripcount = 0 then 0
             else coalesce(occp.matchrateinbound, 0) + coalesce(occp.matchrateoutbound, 0)
        end                                                as tsrateusd,

        case when gb.tripcount = 0 then 0
             else (coalesce(occp.matchrateinbound, 0) + coalesce(occp.matchrateoutbound, 0))
        end * fx.cadrate                                   as tsratecad,

        case when gb.transfertripcount > 0 then 150 else 0 end as transfercostusd,
        case when gb.transfertripcount > 0 then 200 else 0 end as transfercostcad,

        sum(c.contractcostusd)                             as ordercontractcostusd,
        sum(c.contractcostcad)                             as ordercontractcostcad

    from {{ source('pending', 'globalbrokerageanalysis') }} gb
    left join orders_in_contract c on c.contractguid = gb.contractguid
    left join has_trailer         ht on ht.orderguid = gb.orderguid
    left join {{ source('pending', 'ordercartaportelifecycle') }} occp
           on occp.orderguid = gb.orderguid
    left join {{ ref('int_fx_rates_daily') }} fx
           -- NOTE: the original falls back to CURRENT_DATE here too.
           on fx.calendardate = cast(coalesce(gb.delivereddate, current_date) as date)
          and fx.sourcecurrencycode = 'U'
    where (gb.nonmexicotripcount = 0 or gb.tripcount = 0)
      and gb.orderguid is not null
      and coalesce(gb.delivereddate, current_date) >= date '{{ var("brokerage_start_date") }}'
    group by
        gb.orderguid, gb.order_currency, gb.orderno, gb.delivereddate,
        gb.orderrevenue_usd, gb.totalmanualrevenue_usd,
        gb.orderrevenue_cad, gb.totalmanualrevenue_cad,
        gb.tripcount, gb.nonmexicotripcount, gb.transfertripcount,
        gb.equipmenttype, ht.orderguid,
        occp.matchrateinbound, occp.matchrateoutbound, fx.cadrate
),

-- Step 2: totals that reference the aliases above
brokerage as (
    select
        *,
        trailercostusd + transfercostusd + tsrateusd + ordercontractcostusd as totalcontractcostusd,
        trailercostcad + transfercostcad + tsratecad + ordercontractcostcad as totalcontractcostcad
    from brokerage_raw
)

select
    orderguid,
    purebrokerage,
    dispatcher,
    tshybridbrokerage,
    orderno,
    currency,
    ordercontractcostusd            as carriercostusd,
    ordercontractcostcad            as carriercostcad,
    trailercostusd,
    trailercostcad,
    transfercostusd,
    transfercostcad,
    tsrateusd,
    tsratecad,
    totalcontractcostusd            as totalcostusd,
    totalcontractcostcad            as totalcostcad,
    orderrevenuecad - totalcontractcostcad as brokeragegpcad,
    orderrevenueusd - totalcontractcostusd as brokeragegpusd,
    orderrevenuecad                 as brokeragerevenuecad,
    orderrevenueusd                 as brokeragerevenueusd
from brokerage
