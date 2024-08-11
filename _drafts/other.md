### Get list of FK of partition
SELECT format('ALTER TABLE %I DROP CONSTRAINT %I;', conrelid::regclass, conname) FROM pg_constraint WHERE contype='f' AND conrelid='$PARTTITION_NAME'::regclass\gexec