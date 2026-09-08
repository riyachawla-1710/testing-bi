{{ config(materialized='table') }}
-- =============================================================================
-- Port of: BI.ANALYTICS.PREDICTED_REVENUE_BS_VW
--          (populates PREDICTED_REVENUE_BS, 1,115,472 rows)
--
-- Estimates revenue for orders that have NOT been invoiced yet, so the revenue
-- dashboard can show a full month before billing closes. Invoiced orders pass
-- through with their actual charges (the second branch of the UNION ALL).
--
-- HOW THE ESTIMATE IS CHOSEN --------------------------------------------------
-- Six hard overrides first, then a 12-step fallback cascade. The first rule
-- that produces a value wins, and `source` records which one fired:
--
--   OVERRIDES (revenue forced to 1, i.e. effectively excluded)
--     NON BILLABLE PO           po billing status = non-billable
--     LTL ORDER CHARGES         LTL bit set and FRT+FSC > 100  -> uses actual
--     RYDER GM RETURN ROUTE     probill pickup number ends LEG3
--     PENSKE GMM RETURN ROUTE   probill pickup number ends -R
--     HONDA NORTH BOUND LANE    PO number contains NB
--
--   CASCADE (each step only joins when the previous one found nothing)
--     BILLING SYSTEM            actual charges from the OPSYNC billing system
--     CUSTOMER LANE             avg revenue, this customer on this exact lane
--     LANE                      avg revenue, any customer on this lane
--     CUSTOMER STATE LANE       avg rate/mile, this customer, state lane
--     STATE LANE                avg rate/mile, state lane
--     COUNTRY LANE              avg rate/mile, country lane
--     COUNTRY LANE DIRECTION    "                       + direction
--     ORDER DIRECTION           avg rate/mile by direction and distance band
--     STATE-COUNTRY LANE        distinct state+country lane
--     DISTINCT COUNTRY LANE     distinct country lane
--     ROUND TRIP REVENUE        round-trip lanes, multi-probill orders
--     KEURIG SHUNTING REVENUE   Keurig-specific shunting rates
--     CHARGERFLEET              last resort: whatever charges exist
--
-- For distance bands VERY SHORT and SHORT the cascade uses a flat average
-- revenue; for everything longer it uses rate/mile x total_distance.
--
-- DEPENDENCIES NOT YET PORTED -------------------------------------------------
-- The ten lane-rate views are now ported (models/intermediate/lane_rates).
-- Still sources: KEURIG_SHUNTINGREVENUE_VW, TONUORDERSBI_VW and
-- ORDERCHARGES_BS_VW.
--
-- ORDERCHARGES_BS_VW READS OPSYNC.BILLINGSYSTEM.ORDERCHARGE - not Postgres.
-- That is a hard blocker for the BILLING SYSTEM step and needs its own answer.
--
-- POSTGRES PORT NOTES:
--   BITAND(x,n) -> (x & n) · IFF -> case · IFNULL -> coalesce ·
--   CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP) -> current_timestamp at time zone 'UTC'
-- =============================================================================

with not_invoiced as (

    select distinct
        o.orderguid,
        o.orderno,
        o.customer,
        opd.total_distance,
        opd.od_lane,
        opd.od_statelane,
        opd.direction,
        opd.distancetype,

        case
            when po.pobillingstatusid = '9AB995B9-AC05-496A-AB1F-89648CB06794' then o.currency
            when bitand(od.orderproperties, 1) = 1 and (o.frt + o.fsc) > 100 then o.currency
            when exists (select 1 from {{ source('probillsvc', 'probill') }} pp
                         where pp.orderid = od.id
                           and upper(pp.pickupnumber) like '%LEG3'
                           and pp.isrowdeleted = 0)
                 and opd.customer = 'RYDER INTEGRATED LOGISTICS - GM' then o.currency
            when exists (select 1 from {{ source('probillsvc', 'probill') }} pp
                         where pp.orderid = od.id
                           and upper(pp.pickupnumber) like '%-R'
                           and pp.isrowdeleted = 0)
                 and opd.customer = 'PENSKE LOGISTICS GMM' then o.currency
            when upper(od.ponumber) like '%NB%'
                 and opd.customer = 'HONDA NORTH AMERICA INC' then o.currency
            when ob.frt > 100 then coalesce(ar.currency, asr.currency, al.currency, adc.currency, ob.currency)
            when ar.avg_revenue  is not null then ar.currency
            when al.avg_revenue  is not null then al.currency
            when asr.avg_rpm     is not null then asr.currency
            when asl.avg_rpm     is not null then asl.currency
            when acl.avg_rpm     is not null then acl.currency
            when adl.avg_rpm     is not null then adl.currency
            when ard.avg_rpm     is not null then ard.currency
            when adsc.avg_rpm    is not null then adsc.currency
            when adc.avg_rpm     is not null then adc.currency
            when art.avg_rpm     is not null then art.currency
            when ks.avg_revenue  is not null then ks.currency
            when o.totalcharges  is not null then o.currency
        end as currency,

        case
            when po.pobillingstatusid = '9AB995B9-AC05-496A-AB1F-89648CB06794' then 1
            when bitand(od.orderproperties, 1) = 1 and (o.frt + o.fsc) > 100 then o.totalchargesnotax
            when exists (select 1 from {{ source('probillsvc', 'probill') }} pp
                         where pp.orderid = od.id and upper(pp.pickupnumber) like '%LEG3'
                           and pp.isrowdeleted = 0)
                 and opd.customer = 'RYDER INTEGRATED LOGISTICS - GM' then 1
            when exists (select 1 from {{ source('probillsvc', 'probill') }} pp
                         where pp.orderid = od.id and upper(pp.pickupnumber) like '%-R'
                           and pp.isrowdeleted = 0)
                 and opd.customer = 'PENSKE LOGISTICS GMM' then 1
            when upper(od.ponumber) like '%NB%'
                 and opd.customer = 'HONDA NORTH AMERICA INC' then 1
            else coalesce(
                ob.frt + ob.fsc,
                ar.avg_revenue,
                al.avg_revenue,
                case when opd.distancetype not in ('VERY SHORT','SHORT')
                     then asr.avg_rpm  * opd.total_distance else asr.avg_revenue  end,
                case when opd.distancetype not in ('VERY SHORT','SHORT')
                     then asl.avg_rpm  * opd.total_distance else asl.avg_revenue  end,
                case when opd.distancetype not in ('VERY SHORT','SHORT')
                     then acl.avg_rpm  * opd.total_distance else acl.avg_revenue  end,
                case when opd.distancetype not in ('VERY SHORT','SHORT')
                     then adl.avg_rpm  * opd.total_distance else adl.avg_revenue  end,
                case when opd.distancetype not in ('VERY SHORT','SHORT')
                     then ard.avg_rpm  * opd.total_distance else ard.avg_revenue  end,
                case when opd.distancetype not in ('VERY SHORT','SHORT')
                     then adsc.avg_rpm * opd.total_distance else adsc.avg_revenue end,
                case when opd.distancetype not in ('VERY SHORT','SHORT')
                     then adc.avg_rpm  * opd.total_distance else adc.avg_revenue  end,
                case when opd.distancetype not in ('VERY SHORT','SHORT')
                     then art.avg_rpm  * opd.total_distance else art.avg_revenue  end,
                ks.avg_revenue,
                o.totalcharges
            )
        end as predicted_revenue,

        o.invoicestatus,

        case
            when po.pobillingstatusid = '9AB995B9-AC05-496A-AB1F-89648CB06794' then 'NON BILLABLE PO'
            when bitand(od.orderproperties, 1) = 1 and (o.frt + o.fsc) > 100 then 'LTL ORDER CHARGES'
            when exists (select 1 from {{ source('probillsvc', 'probill') }} pp
                         where pp.orderid = od.id and upper(pp.pickupnumber) like '%LEG3'
                           and pp.isrowdeleted = 0)
                 and opd.customer = 'RYDER INTEGRATED LOGISTICS - GM' then 'RYDER GM RETURN ROUTE'
            when exists (select 1 from {{ source('probillsvc', 'probill') }} pp
                         where pp.orderid = od.id and upper(pp.pickupnumber) like '%-R'
                           and pp.isrowdeleted = 0)
                 and opd.customer = 'PENSKE LOGISTICS GMM' then 'PENSKE GMM RETURN ROUTE'
            when upper(od.ponumber) like '%NB%'
                 and opd.customer = 'HONDA NORTH AMERICA INC' then 'HONDA NORTH BOUND LANE'
            when ob.customer     is not null then 'BILLING SYSTEM'
            when ar.avg_revenue  is not null then 'CUSTOMER LANE'
            when al.avg_revenue  is not null then 'LANE'
            when asr.avg_rpm     is not null then 'CUSTOMER STATE LANE'
            when asl.avg_rpm     is not null then 'STATE LANE'
            when acl.avg_rpm     is not null then 'COUNTRY LANE'
            when adl.avg_rpm     is not null then 'COUNTRY LANE DIRECTION'
            when ard.avg_rpm     is not null then 'ORDER DIRECTION'
            when adsc.avg_rpm    is not null then 'STATE-COUNTRY LANE'
            when adc.avg_rpm     is not null then 'DISTINCT COUNTRY LANE'
            when art.avg_revenue is not null then 'ROUND TRIP REVENUE'
            when ks.avg_revenue  is not null then 'KEURIG SHUNTING REVENUE'
            when o.totalcharges  is not null then 'CHARGERFLEET'
        end as source

    from {{ source('probillsvc', 'order') }} od
    left join {{ source('probillsvc', 'po') }} po on od.poid = po.id and po.isrowdeleted = 0
    left join {{ ref('int_order_charges_with_adjustment') }} o on od.id = o.orderguid
    left join {{ source('pending', 'labatt_orderrevenue') }} lb on lb.orderguid = od.id
    left join {{ source('pending', 'ordercharges_bs_vw') }} ob on ob.orderguid = od.id
    left join {{ source('probillsvc', 'probill') }} p on od.id = p.orderid and p.isrowdeleted = 0
    left join {{ ref('int_opd_miles') }} opd on o.orderguid = opd.orderguid
    left join {{ source('pending', 'tonuordersbi_vw') }} tb on tb.orderid = od.id

    -- the cascade: each join is gated on the previous one finding nothing
    left join {{ ref('int_lane_rate_by_customer_lane') }} ar
           on o.customer = ar.customer and opd.od_lane = ar.od_lane
    left join {{ ref('int_lane_rate_by_lane') }} al
           on opd.od_lane = al.od_lane
          and ar.avg_revenue is null
    left join {{ ref('int_lane_rate_by_customer_statelane') }} asr
           on o.customer = asr.customer and opd.od_statelane = asr.od_statelane
          and opd.direction_ns = asr.direction and opd.distancetype = asr.distancetype
          and al.avg_revenue is null
    left join {{ ref('int_lane_rate_by_statelane') }} asl
           on opd.od_statelane = asl.od_statelane
          and opd.direction_ns = asl.direction and opd.distancetype = asl.distancetype
          and asr.avg_rpm is null
    left join {{ ref('int_lane_rate_by_countrylane') }} acl
           on opd.od_countrylane = acl.od_countrylane
          and opd.distancetype = acl.distancetype and opd.direction = acl.direction
          and asl.avg_rpm is null
    left join {{ ref('int_lane_rate_by_countrylane_direction') }} adl
           on opd.od_countrylane = adl.od_countrylane
          and opd.distancetype = adl.distancetype and opd.direction_ns = adl.direction
          and acl.avg_rpm is null
    left join {{ ref('int_lane_rate_by_direction') }} ard
           on opd.direction = ard.direction and opd.distancetype = ard.distancetype
          and adl.avg_rpm is null
    left join {{ ref('int_lane_rate_by_distinct_state_country_lane') }} adsc
           on opd.order_direction = adsc.order_direction
          and opd.distancetype = adsc.distancetype
          and opd.od_statelane_distinct = adsc.od_statelane_distinct
          and opd.od_countrylane_distinct = adsc.od_countrylane_distinct
          and od.currency = adsc.currency
          and ard.avg_rpm is null
    left join {{ ref('int_lane_rate_by_distinct_country_lane') }} adc
           on opd.order_direction = adc.order_direction
          and case when opd.distancetype in ('VERY LONG','LONG') then 'LONG'
                   else opd.distancetype end = adc.distancetype
          and opd.od_countrylane_distinct = adc.od_countrylane_distinct
          and od.currency = adc.currency
          and adsc.avg_rpm is null
    left join {{ ref('int_lane_rate_by_countrylane_roundtrip') }} art
           on case when opd.roundtrip_check then 'RT' else opd.order_direction end = art.order_direction
          and case when opd.distancetype in ('VERY LONG','LONG','MEDIUM') then 'LONG'
                   else opd.distancetype end = art.distancetype
          and opd.od_countrylane_distinct = art.od_countrylane_distinct
          and opd.countriescount = art.countriescount
          and od.currency = art.currency
          and opd.probillcount > 1
          and adc.avg_rpm is null
    left join {{ source('pending', 'keurig_shuntingrevenue_vw') }} ks
           on ks.od_statelane_distinct = opd.od_statelane_distinct
          and od.currency = ks.currency
          and opd.customer = 'KEURIG CANADA INC.'

    where (od.invoiceid is null
           or (o.invoicedate is null
               and o.customer = 'LABATT BREWING CO LTD (SHUTTLE)'
               and o.totalcharges <= 1))
      and od.isrowdeleted = 0
      and (od.delivereddate >= date '{{ var("brokerage_start_date") }}' or od.delivereddate is null)
      and od.externalid >= {{ var("min_order_number") }}
      and opd.probillcount > 0
),

invoiced as (
    -- Already invoiced: no estimate needed, use the real charges
    select distinct
        o.orderguid,
        o.orderno,
        o.customer,
        opd.total_distance,
        opd.od_lane,
        opd.od_statelane,
        opd.direction,
        opd.distancetype,
        o.currency,
        o.totalchargesnotax as predicted_revenue,
        o.invoicestatus,
        'INVOICE'           as source
    from {{ source('probillsvc', 'order') }} od
    left join {{ ref('int_order_charges_with_adjustment') }} o on od.id = o.orderguid
    left join {{ ref('int_opd_miles') }} opd on o.orderguid = opd.orderguid
    where not (od.invoiceid is null
               or (o.invoicedate is null
                   and o.customer = 'LABATT BREWING CO LTD (SHUTTLE)'
                   and o.totalcharges <= 1))
      and od.isrowdeleted = 0
      and od.externalid >= {{ var("min_order_number") }}
      and (od.delivereddate >= date '{{ var("brokerage_start_date") }}' or od.delivereddate is null)
      and od.orderstatusid <> '{{ var("order_status_cancelled_id") }}'
),

combined as (
    select * from not_invoiced
    union all
    select * from invoiced
)

select
    *,
    {{ dbt.current_timestamp() }}            as createdon,
    'PREDICTED REVENUE JOB'                  as createdby,
    cast(null as {{ dbt.type_timestamp() }}) as modifiedon,
    cast(null as {{ dbt.type_string() }})    as modifiedby
from combined
