{{ config(materialized='view') }}
-- =============================================================================
-- Port of: BI.ANALYTICS.BOCDAILYFXRATES_VW
--
-- Builds a dense daily calendar per currency from 2017-01-03 and forward-fills
-- the last known rate across weekends, holidays and future dates.
--
-- POSTGRES PORT NOTES:
--   * TABLE(GENERATOR(ROWCOUNT => n)) -> generate_series(). Rewritten below
--     using dbt_utils.date_spine, which compiles correctly on both adapters.
--   * IFNULL -> COALESCE (done)
--   * LAST_VALUE(... IGNORE NULLS) -> Postgres has no IGNORE NULLS. Use the
--     max(...) FILTER / gap-fill idiom shown in the note at the bottom.
-- =============================================================================

with calendar as (
    {{ dbt_utils.date_spine(
        datepart="day",
        start_date="cast('2017-01-03' as date)",
        end_date="cast(current_date + interval '365 day' as date)"
    ) }}
),

currencies as (
    select 'CAD' as sourcecurrency, 'C' as sourcecurrencycode
    union all select 'USD', 'U'
    union all select 'MXN', 'P'
),

calendar_x_currency as (
    select
        cast(c.date_day as date) as calendardate,
        cur.sourcecurrency,
        cur.sourcecurrencycode
    from calendar c
    cross join currencies cur
),

boc_daily as (
    -- Normalise the raw Workday feed into one row per (date, currency)
    select
        date                    as calendardate,
        'CAD'                   as sourcecurrency,
        'C'                     as sourcecurrencycode,
        1.00                    as cadrate,
        1 / "USD/CAD"           as usdrate,
        1 / "MXN/CAD"           as mxnrate,
        'BOC'                   as forexsource
    from {{ source('workdaybi', 'bocdailyfxrates') }}
    where "MXN/CAD" is not null or "USD/CAD" is not null

    union all
    select
        date, 'USD', 'U',
        "USD/CAD",
        1.00,
        "USD/CAD" / "MXN/CAD",
        'BOC'
    from {{ source('workdaybi', 'bocdailyfxrates') }}
    where "MXN/CAD" is not null or "USD/CAD" is not null

    union all
    select
        date, 'MXN', 'P',
        "MXN/CAD",
        "MXN/CAD" / "USD/CAD",
        1.00,
        'BOC'
    from {{ source('workdaybi', 'bocdailyfxrates') }}
    where "MXN/CAD" is not null or "USD/CAD" is not null
),

aligned as (
    select
        cal.calendardate,
        cal.sourcecurrency,
        cal.sourcecurrencycode,
        fx.cadrate,
        fx.usdrate,
        fx.mxnrate,
        coalesce(fx.forexsource, 'LATEST TILL DATE') as forexsource
    from calendar_x_currency cal
    left join boc_daily fx
           on cal.calendardate  = fx.calendardate
          and cal.sourcecurrency = fx.sourcecurrency
),

filled as (
    -- Forward-fill the most recent non-null rate
    select
        calendardate,
        sourcecurrency,
        sourcecurrencycode,
        last_value(cadrate ignore nulls) over (
            partition by sourcecurrency order by calendardate
            rows between unbounded preceding and current row) as cadrate,
        last_value(usdrate ignore nulls) over (
            partition by sourcecurrency order by calendardate
            rows between unbounded preceding and current row) as usdrate,
        last_value(mxnrate ignore nulls) over (
            partition by sourcecurrency order by calendardate
            rows between unbounded preceding and current row) as mxnrate,
        forexsource
    from aligned
)

select distinct
    calendardate,
    sourcecurrency,
    sourcecurrencycode,
    cadrate,
    usdrate,
    mxnrate,
    forexsource
from filled

-- POSTGRES REPLACEMENT for the `filled` CTE (no IGNORE NULLS in Postgres):
--
--   , grp as (
--       select *,
--              count(cadrate) over (partition by sourcecurrency
--                                   order by calendardate) as g_cad
--       from aligned
--   )
--   select calendardate, sourcecurrency, sourcecurrencycode,
--          max(cadrate) over (partition by sourcecurrency, g_cad) as cadrate,
--          ...
--   from grp
