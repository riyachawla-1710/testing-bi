
    
    

select
    orderid as unique_field,
    count(*) as n_records

from "test"."reporting_intermediate"."int_tonu_orders"
where orderid is not null
group by orderid
having count(*) > 1


