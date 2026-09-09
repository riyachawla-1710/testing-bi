
  
    

  create  table "test"."reporting_intermediate"."int_opd_miles__dbt_tmp"
  
  
    as
  
  (
    
-- =============================================================================
-- Port of: BI.ANALYTICS.OPD_MILES_VW  (populates the OPD_MILES table, 1,114,454 rows)
--
-- Reconstructs each order's journey from its probill pickup/delivery events,
-- orders those events, pairs consecutive stops, looks up leg mileage from
-- ADDRESSSVC.TRAVELTIME (trying both directions, then parent locations), and
-- rolls the legs up into one row per order with lanes, direction and distance.
--
-- Everything it reads is CHARGERFLEET (Postgres-derived). No external systems.
--
-- POSTGRES PORT NOTES - READ BEFORE SWITCHING TARGET -------------------------
--
-- 1. LAST_VALUE DEFAULT FRAME. This is the dangerous one. Snowflake defaults
--    FIRST_VALUE/LAST_VALUE to the WHOLE partition; Postgres defaults to
--    "unbounded preceding to current row", which makes LAST_VALUE return the
--    CURRENT row. Every LAST_VALUE below therefore needs an explicit
--    `rows between unbounded preceding and unbounded following` on Postgres,
--    or DELCITY/DELSTATE/DELCOUNTRY silently become the pickup values.
--
-- 2. string_agg(DISTINCT x, sep order by y). Postgres cannot do
--    DISTINCT and ORDER BY on different expressions in string_agg. Pre-dedupe
--    in a subquery, then string_agg(x, sep order by y).
--
-- 3. GREATEST WITH NULLS. Snowflake's GREATEST returns NULL if any argument is
--    NULL; Postgres ignores NULLs. The MINUTES calculation relies on that,
--    so wrap each argument or the result changes.
--
-- 4. Mechanical: (x & n) -> (x & n) · IFNULL -> coalesce ·
--    ARRAY_SIZE(ARRAY_AGG(DISTINCT x)) -> count(distinct x) ·
--    UUID_STRING() -> gen_random_uuid() ·
--    CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP) -> current_timestamp at time zone 'UTC'
--
-- HARDCODED ORDER GUIDS. Two specific orders are patched by GUID:
--    755A4644-... forced to SPOT
--    2F2E282F-... given 182 miles / 180 minutes
-- Kept for fidelity. They are data fixes living in code - move to a seed.
-- =============================================================================

-- Per-order aggregates. Snowflake computed these as COUNT(DISTINCT ...) OVER
-- (PARTITION BY o.id); PostgreSQL does not implement DISTINCT for window
-- functions, so they are grouped here over the same join graph and joined back.
-- Same rows in, same values out.
with order_probill_agg as (
    select
        o.id                                                      as orderguid,
        min(pd.actualpickupdt1)                                   as min_actual_pickup,
        max(pd.actualdeldt1)                                      as max_actual_del,
        count(distinct pd.actualdeldt1)                           as actual_del_count,
        count(distinct p.id)                                      as probillcount,
        count(distinct tt.name)                                   as trailertype_count,
        max(case when tt.name ilike '%REEFER%' then 1 else 0 end) as has_reefer

    from "test"."probillsvc"."order" o
    left join "test"."probillsvc".probill p
           on o.id = p.orderid and p.isrowdeleted = false
    left join "test"."probillsvc".pickdeldates pd
           on pd.probillid = p.id and pd.isrowdeleted = false
    left join "test"."trailersvc"."trailertype" tt on p.trailertypeid = tt.id
    where o.isrowdeleted = false
      and o.externalid >= 10000000
      and o.orderstatusid <> 'ABD88AC0-5970-40DA-8382-53DD000300B7'
    group by o.id
),

orderdata as (
    select
        o.id                            as orderguid,
        o.externalid                    as orderno,
        cast(i.invoiceddate as date)    as orderinvoiceddate,
        case
            when o.id = '755A4644-DA61-4441-1ECE-08DCB60CD590' then 'SPOT'
            when (o.orderproperties & 2) = 2 then 'SPOT'
            else 'NOT SPOT'
        end                             as spot_status,
        c.legalbusinessname             as customer,
        o.orderdate,
        coalesce(o.pickedupdate, agg.min_actual_pickup) as pickedupdate,

        -- delivered only once every probill has an actual delivery datetime
        coalesce(o.delivereddate,
                 case when agg.actual_del_count = agg.probillcount
                      then agg.max_actual_del end)       as delivereddate,

        p.id                            as probillid,
        case
            when agg.trailertype_count > 1
                then case when agg.has_reefer = 1 then 'REEFER' else 'DRY-VAN' end
            else tt.name
        end                             as equipmenttype,
        p.pickuplocationid,
        p.deliverylocationid,
        coalesce(pd.actualpickupdt1, pd.pickupdt1) as pickupeventdate,
        pd.pickupdt1                    as pickupetadate,
        coalesce(pd.actualdeldt1, pd.deldt1)       as deliveryeventdate,
        pd.deldt1                       as deliveryetadate,
        agg.probillcount

    from "test"."probillsvc"."order" o
    join order_probill_agg agg on agg.orderguid = o.id
    left join "test"."invoicesvc"."invoice" i
           on i.id = o.invoiceid
          and i.isrowdeleted = false
          and i.invoicestatusid <> '8ACBC9AB-0298-43E1-85C7-DDE861F8B32C'
    left join "test"."customersvc"."customer" c on c.id = o.customerid
    left join "test"."probillsvc".probill p
           on o.id = p.orderid and p.isrowdeleted = false
    left join "test"."probillsvc".pickdeldates pd
           on pd.probillid = p.id and pd.isrowdeleted = false
    left join "test"."trailersvc"."trailertype" tt on p.trailertypeid = tt.id
    where o.isrowdeleted = false
      and o.externalid >= 10000000
      and o.orderstatusid <> 'ABD88AC0-5970-40DA-8382-53DD000300B7'
),

-- One row per stop: pickups and deliveries unioned
events as (
    select orderguid, orderno, orderinvoiceddate, spot_status, customer, orderdate,
           pickedupdate, delivereddate, probillid, equipmenttype,
           pickuplocationid as locationid,
           pickupeventdate  as eventdate,
           pickupetadate    as etadate,
           probillcount,
           'PICKUP'         as loctype
    from orderdata
    union all
    select orderguid, orderno, orderinvoiceddate, spot_status, customer, orderdate,
           pickedupdate, delivereddate, probillid, equipmenttype,
           deliverylocationid, deliveryeventdate, deliveryetadate, probillcount,
           'DELIVERY'
    from orderdata
),

orderedevents as (
    select
        oe.*,
        coalesce(l.parentlocationid, l.id) as parentlocationid,
        l.address1                         as address,
        l.name                             as locationname,
        l.lat,
        l.lon,
        upper(l.city)                      as city,
        case when j.code = 'QR' then 'QA'
             when j.code = 'PQ' then 'QC'
             when j.code = 'DF' then 'MX'
             else j.code end               as state,
        j.country,
        -- four candidate orderings; FAILCHECK picks one per order
        row_number() over (partition by orderguid
            order by case when loctype = 'PICKUP' then 1 else 2 end) as rns,
        row_number() over (partition by orderguid order by eventdate, etadate) as rno,
        row_number() over (partition by orderguid order by etadate, eventdate) as rnb,
        row_number() over (partition by orderguid order by l.lat, etadate)     as rnl,
        -- ACTUAL when a pickup is immediately followed by its delivery
        case when loctype = 'PICKUP' then
                case when lead(loctype) over (partition by orderguid, probillid
                                              order by eventdate, l.lat) = 'DELIVERY'
                     then 'ACTUAL' else 'ETA' end
             else
                case when lag(loctype) over (partition by orderguid, probillid
                                             order by eventdate, l.lat) = 'PICKUP'
                     then 'ACTUAL' else 'ETA' end
        end as flag
    from events oe
    left join "test"."fleetsvc"."location" l     on l.id = oe.locationid
    left join "test"."fleetsvc"."jurisdiction" j on l.jurisdictionid = j.id
),

-- If at least as many stops are ETA-based as ACTUAL-based, trust the ETA order
failproff as (
    select distinct
        orderguid,
        case when count(case when flag = 'ETA' then 1 end) over (partition by orderguid)
                >= count(case when flag = 'ACTUAL' then 1 end) over (partition by orderguid)
             then 'ETA' else 'ACTUAL' end as decision
    from orderedevents
),

failcheck as (
    select
        o.*,
        case
            when o.probillcount = 1 then o.rns
            -- Colgate multi-stop routes order by latitude, not by date
            when o.customer like 'COLGATE-PALMOLIVE%' and o.probillcount >= 3 then o.rnl
            when f.decision = 'ETA' then o.rnb
            else o.rno
        end as rn
    from orderedevents o
    left join failproff f on o.orderguid = f.orderguid
),

-- Pair each stop with the next one and price the leg
milescalculation as (
    select distinct
        oe1.orderguid, oe1.orderdate, oe1.orderinvoiceddate, oe1.delivereddate,
        oe1.pickedupdate, oe1.orderno, oe1.customer, oe1.probillcount,
        oe1.equipmenttype, oe1.spot_status, oe1.eventdate,
        oe1.locationid as from_location,
        oe2.locationid as to_location,
        oe1.rn,
        oe1.lat as from_lat, oe1.lon as from_lon,
        oe2.lat as to_lat,   oe2.lon as to_lon,
        oe1.city as from_city, oe2.city as to_city,
        oe1.state as from_state, oe2.state as to_state,
        oe1.country as from_country, oe2.country as to_country,

        first_value(oe1.address)      over (partition by oe1.orderguid order by oe1.rn) as pick_address,
        last_value(oe2.address)       over (partition by oe1.orderguid order by oe2.rn) as del_address,
        first_value(oe1.locationname) over (partition by oe1.orderguid order by oe1.rn) as pick_locationname,
        last_value(oe2.locationname)  over (partition by oe1.orderguid order by oe2.rn) as del_locationname,
        first_value(oe1.lat)          over (partition by oe1.orderguid order by oe1.rn) as first_lat,
        last_value(oe2.lat)           over (partition by oe1.orderguid order by oe2.rn) as last_lat,
        first_value(oe1.lon)          over (partition by oe1.orderguid order by oe1.rn) as first_lon,
        last_value(oe2.lon)           over (partition by oe1.orderguid order by oe2.rn) as last_lon,
        first_value(oe1.city)         over (partition by oe1.orderguid order by oe1.rn) as pickcity,
        last_value(oe2.city)          over (partition by oe1.orderguid order by oe2.rn) as delcity,
        first_value(oe1.state)        over (partition by oe1.orderguid order by oe1.rn) as pickstate,
        last_value(oe2.state)         over (partition by oe1.orderguid order by oe2.rn) as delstate,
        first_value(oe1.country)      over (partition by oe1.orderguid order by oe1.rn) as pickcountry,
        last_value(oe2.country)       over (partition by oe1.orderguid order by oe2.rn) as delcountry,

        case when coalesce(tt1.miles, tt2.miles, ttp1.miles, ttp2.miles) is not null
                  then coalesce(tt1.miles, tt2.miles, ttp1.miles, ttp2.miles)
             when oe1.locationid = oe2.locationid then 0
             when oe1.parentlocationid = oe2.parentlocationid then 0
             when oe1.orderguid = '2F2E282F-C297-4B56-240C-08DBDA2958CB' then 182
        end as miles,

        case when greatest(
                    coalesce(tt1.apipostalminutes, tt2.apipostalminutes, ttp1.apipostalminutes, ttp2.apipostalminutes),
                    coalesce(tt1.apiaddressmiles,  tt2.apiaddressmiles,  ttp1.apiaddressmiles,  ttp2.apiaddressmiles),
                    coalesce(tt1.apistreetmiles,   tt2.apistreetmiles,   ttp1.apistreetmiles,   ttp2.apistreetmiles)
                  ) is not null
                  then greatest(
                    coalesce(tt1.apipostalminutes, tt2.apipostalminutes, ttp1.apipostalminutes, ttp2.apipostalminutes),
                    coalesce(tt1.apiaddressmiles,  tt2.apiaddressmiles,  ttp1.apiaddressmiles,  ttp2.apiaddressmiles),
                    coalesce(tt1.apistreetmiles,   tt2.apistreetmiles,   ttp1.apistreetmiles,   ttp2.apistreetmiles)
                  )
             when oe1.locationid = oe2.locationid then 0
             when oe1.parentlocationid = oe2.parentlocationid then 0
             when oe1.orderguid = '2F2E282F-C297-4B56-240C-08DBDA2958CB' then 180
        end as minutes

    from failcheck oe1
    join failcheck oe2
      on oe1.orderguid = oe2.orderguid
     and oe1.rn = oe2.rn - 1
    -- mileage: try A->B, then B->A, then parent A->B, then parent B->A
    left join "test"."addresssvc"."traveltime" tt1
           on tt1.fromlocid = oe1.locationid and tt1.tolocid = oe2.locationid
          and tt1.isrowdeleted = false
    left join "test"."addresssvc"."traveltime" tt2
           on tt2.fromlocid = oe2.locationid and tt2.tolocid = oe1.locationid
          and tt2.isrowdeleted = false and tt1.miles is null
    left join "test"."addresssvc"."traveltime" ttp1
           on ttp1.fromlocid = oe1.parentlocationid and ttp1.tolocid = oe2.parentlocationid
          and ttp1.isrowdeleted = false and tt2.miles is null
    left join "test"."addresssvc"."traveltime" ttp2
           on ttp2.fromlocid = oe2.parentlocationid and ttp2.tolocid = oe1.parentlocationid
          and ttp2.isrowdeleted = false and ttp1.miles is null
)
,

-- Distinct states/countries touched by the whole order
probillcountries as (
    select
        orderguid,
        string_agg(distinct state,   ', ' order by state)   as distinctstates,
        string_agg(distinct country, ', ' order by country) as distinctcountries,
        count(distinct country)                                        as countriescount
    from (
        select distinct orderguid, from_country as country, from_state as state from milescalculation
        union
        select distinct orderguid, to_country,              to_state            from milescalculation
    ) s
    group by orderguid
),

-- Roll the legs up to one row per order
miles_sum as (
    select
        orderguid,
        -- NULL unless EVERY leg has a mileage: a partial total would be wrong
        case when count(miles)   < count(*) then null else sum(miles)   end as total_distance,
        case when count(minutes) < count(*) then null else sum(minutes) end as etaminutes,

        -- compass bearing per leg, by the larger of the lat/lon deltas
        string_agg(distinct case
            when abs(to_lat - from_lat) >= abs(to_lon - from_lon)
                then case when to_lat > from_lat then 'NB'
                          when to_lat < from_lat then 'SB' end
            when abs(to_lon - from_lon) >  abs(to_lat - from_lat)
                then case when to_lon > from_lon then 'EB'
                          when to_lon < from_lon then 'WB' end
        end, ' & ')                                                    as direction,

        -- north/south only - what the lane rate tables are keyed on
        string_agg(distinct case
            when abs(to_lat - from_lat) >= abs(to_lon - from_lon)
                then case when to_lat > from_lat then 'NB'
                          when to_lat < from_lat then 'SB' end
            when abs(to_lon - from_lon) >  abs(to_lat - from_lat)
                then case when to_lat > from_lat then 'NB'
                          when to_lat < from_lat then 'SB' end
        end, ' & ')                                                    as direction_ns,

        -- both NB and SB legs present => the order came back
        case when count(distinct case
                when abs(to_lat - from_lat) >= abs(to_lon - from_lon)
                    then case when to_lat > from_lat then 'NB'
                              when to_lat < from_lat then 'SB' end
                when abs(to_lon - from_lon) >  abs(to_lat - from_lat)
                    then case when to_lat > from_lat then 'NB'
                              when to_lat < from_lat then 'SB' end
             end) = 2 then true else false end                         as roundtrip_check,

        string_agg(from_city || ', ' || from_state || ' - ' || to_city || ', ' || to_state, ' & ' order by rn)                                 as od_lane,
        string_agg(from_state   || ' - ' || to_state,   ' & ' order by rn) as od_statelane,
        string_agg(from_country || ' - ' || to_country, ' & ' order by rn) as od_countrylane,
        string_agg(to_country   || ' - ' || from_country, ' & ' order by rn)      as od_reverse_countrylane,
        string_agg(to_state     || ' - ' || from_state,   ' & ' order by rn desc) as od_reverse_statelane
    from milescalculation
    group by orderguid
),

opd_miles as (
    select distinct
        m2.orderguid,
        m2.orderno,
        m2.orderinvoiceddate,
        m2.customer,
        m2.probillcount,
        m2.spot_status,
        m2.orderdate,
        m2.pickedupdate,
        m2.delivereddate,
        m2.equipmenttype,

        -- distance banding drives which lane rate table gets used downstream
        case when ms.total_distance <  20                                  then 'VERY SHORT'
             when ms.total_distance >  20   and ms.total_distance <=  100   then 'SHORT'
             when ms.total_distance >  100  and ms.total_distance <=  500   then 'MEDIUM'
             when ms.total_distance >  500  and ms.total_distance <   3000  then 'LONG'
             when ms.total_distance >  3000                                 then 'VERY LONG'
        end                                                             as distancetype,

        ms.direction,
        ms.direction_ns,
        ms.roundtrip_check,

        -- whole-order bearing, first stop to last. 'RT' when it returns.
        coalesce(case
            when abs(m2.last_lat - m2.first_lat) >= abs(m2.last_lon - m2.first_lon)
                then case when m2.last_lat > m2.first_lat then 'NB'
                          when m2.last_lat < m2.first_lat then 'SB' end
            when abs(m2.last_lon - m2.first_lon) >  abs(m2.last_lat - m2.first_lat)
                then case when m2.last_lat > m2.first_lat then 'NB'
                          when m2.last_lat < m2.first_lat then 'SB' end
        end, 'RT')                                                      as order_direction_ns,

        coalesce(case
            when abs(m2.last_lat - m2.first_lat) >= abs(m2.last_lon - m2.first_lon)
                then case when m2.last_lat > m2.first_lat then 'NB'
                          when m2.last_lat < m2.first_lat then 'SB' end
            when abs(m2.last_lon - m2.first_lon) >  abs(m2.last_lat - m2.first_lat)
                then case when m2.last_lon > m2.first_lon then 'EB'
                          when m2.last_lon < m2.first_lon then 'WB' end
        end, 'RT')                                                      as order_direction,

        m2.first_lat as picklat,
        m2.last_lat  as dellat,
        m2.first_lon as picklon,
        m2.last_lon  as dellon,
        m2.pick_address,
        m2.del_address,
        m2.pick_locationname,
        m2.del_locationname,
        m2.pickcity,
        m2.delcity,
        m2.pickstate,
        m2.delstate,
        m2.pickcountry,
        m2.delcountry,

        ms.od_lane,
        ms.od_statelane,
        ms.od_countrylane,

        -- "distinct" lanes ignore intermediate stops: first origin to last destination
        m2.pickcity  || ', ' || m2.pickstate || ' - ' || m2.delcity || ', ' || m2.delstate
                                                                        as od_lane_distinct,
        m2.pickstate   || ' - ' || m2.delstate                          as od_statelane_distinct,
        m2.pickcountry || ' - ' || m2.delcountry                        as od_countrylane_distinct,

        pc.distinctstates,
        pc.distinctcountries,
        pc.countriescount,
        ms.od_reverse_countrylane,
        ms.od_reverse_statelane,
        ms.total_distance,
        ms.etaminutes

    from milescalculation m2
    left join probillcountries pc on pc.orderguid = m2.orderguid
    left join miles_sum       ms on ms.orderguid = m2.orderguid
    -- a multi-stop order must actually move between locations
    where case when m2.probillcount > 1 then m2.from_location <> m2.to_location else true end
)

select
    *,
    now() as createdon,
    'OPD MILES JOB'               as createdby,
    cast(null as timestamp) as modifiedon,
    cast(null as TEXT)    as modifiedby
from opd_miles
  );
  