
    
    select
      count(*) as failures,
      count(*) != 0 as should_warn,
      count(*) != 0 as should_error
    from (
      
    
  
    
    



select orderid
from "test"."reporting_intermediate"."int_tonu_orders"
where orderid is null



  
  
      
    ) dbt_internal_test