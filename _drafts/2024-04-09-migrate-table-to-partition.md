---
layout: post
title: Migrate table to partition in PostgreSQ (part2)L
date: 2024-02-25
---

Here is the link to firest part of acrticle [Adding an Existing Table as a Large Partition in PostgreSQL (part 1)](https://boosterkrd.github.io/2024/02/25/migrate-table-to-partition.html) 

let's do it 
<!--MORE-->

-----

## Step 0: Setting Up the Test Environment
  ```sql
  create table orig_table
  ( id serial not null,
    data float default random() not NULL,
    dt timestamp not NULL
  );

  insert into orig_table (id, dt)
    select nextval('orig_table_id_seq'),
    timestamp '2022-09-01 20:00:00' + random() * (timestamp '2022-12-31 20:00:00' - timestamp '2022-09-10 10:00:00') 
    from generate_series(1,3000000);

  create index orig_data_index on orig_table(data);
  create index orig_id_index on orig_table(id);
  -------------
  create table part_table
  (like orig_table including defaults including indexes including constraints)
  partition by range(dt);


  create table part_table_09 partition of part_table for values from ('2022-09-01 00:00:00') to ('2022-10-01 00:00:00');
  create table part_table_10 partition of part_table for values from ('2022-10-01 00:00:00') to ('2022-11-01 00:00:00');
  create table part_table_11 partition of part_table for values from ('2022-11-01 00:00:00') to ('2022-12-01 00:00:00');
  create table part_table_12 partition of part_table for values from ('2022-12-01 00:00:00') to ('2023-01-01 00:00:00');


  -------------------------
  create or replace function part_v_trigger()
  returns trigger
  language plpgsql
  as
  $TRIG$

  begin
      IF TG_OP = 'INSERT'
      THEN
          INSERT INTO part_table VALUES(NEW.id, NEW.data, NEW.dt);
          RETURN NEW;
      ELSIF TG_OP = 'DELETE'
      THEN
          DELETE FROM part_table WHERE id = OLD.id;
          DELETE FROM old_orig_table WHERE id = OLD.id;
          RETURN OLD;
      ELSE -- UPDATE
          DELETE FROM old_orig_table WHERE id = OLD.id;
          IF FOUND
          THEN
              INSERT INTO part_table VALUES(NEW.id, NEW.data, NEW.dt);
          ELSE
              UPDATE part_table SET id = NEW.id, data = NEW.data, dt = NEW.dt
                  WHERE id = OLD.id;
          END IF;
          RETURN NEW;
      END IF;
  end

  $TRIG$;

  BEGIN;
  ALTER TABLE orig_table RENAME TO old_orig_table;
  ALTER TABLE old_orig_table SET(autovacuum_enabled = false, toast.autovacuum_enabled = false);
  
  CREATE VIEW orig_table AS
      SELECT id, data,dt FROM old_orig_table
      UNION ALL
      SELECT id, data,dt FROM part_table;
      
      CREATE TRIGGER orig_table_part_trigger
      INSTEAD OF INSERT OR UPDATE OR DELETE on orig_table
      FOR EACH ROW
      EXECUTE FUNCTION part_v_trigger();
      
  COMMIT;   
  ```


## Step 1: Preparing the Table for Partitioning
  ```sql
DO $$ 
DECLARE 
    v_start_id INTEGER := 1; 
    v_end_id INTEGER := 3000000; 
    v_step INTEGER := 50000; 
BEGIN 
    FOR i IN v_start_id..v_end_id BY v_step LOOP 
        -- Выводим сообщение перед началом обработки текущего диапазона
        RAISE NOTICE 'Начинается цикл с % по %', i, i + v_step;
        BEGIN 
            -- Выполнение вставки через CTE 
            WITH delold AS (
                DELETE 
                FROM old_orig_table 
               WHERE id >= i AND id < i + v_step
                RETURNING id, data, dt
            )
            INSERT INTO part_table 
            SELECT * 
            FROM delold;
        EXCEPTION 
            WHEN OTHERS THEN 
                -- Обработка ошибок
                RAISE NOTICE 'Error processing range % - %', i, i + v_step;
        END; 
        -- Пауза на 500 мс 
        PERFORM pg_sleep(0.5); 
    END LOOP; 
END $$;
  ```

drop table part_table CASCADE;

drop table old_orig_table;

TEST



select * from orig_table where id=1630002;
    begin;
    delete from orig_table where id=1630002;
    commit;
select * from orig_table where id=1630002;
select * from orig_table where id=2000005;
    begin;
    update orig_table  set data=666 where id=2000005;
    commit;
select * from orig_table where id=2000005;
 

