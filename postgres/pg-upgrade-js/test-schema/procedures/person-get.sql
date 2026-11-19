create or replace procedure person_get(
    p_id varchar(255)
)
language plpgsql
as $$
begin
 select * from person where id = p_user_id;
end;
$$;

