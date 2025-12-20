DROP TABLE IF EXISTS test_data;

CREATE TABLE test_data (
    id UUID NOT NULL,
    user_id UUID NOT NULL,
    created_at TIMESTAMP NOT NULL,
    updated_at TIMESTAMP NOT NULL,
    val_int INTEGER NOT NULL,
    val_big BIGINT NOT NULL,
    val_bool BOOLEAN NOT NULL
);

INSERT INTO test_data (id, user_id, created_at, updated_at, val_int, val_big, val_bool)
SELECT
    gen_random_uuid(),
    gen_random_uuid(),
    NOW() + (random() * interval '1 year'),
    NOW() + (random() * interval '1 year'),
    (random() * 1000000)::int,
    (random() * 1000000000000)::bigint,
    (random() > 0.5)
FROM generate_series(1, 100000);

SELECT count(*) as total_rows FROM test_data;
