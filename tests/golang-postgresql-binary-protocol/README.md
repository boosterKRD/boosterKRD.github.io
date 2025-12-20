# PostgreSQL Protocol Comparison Test

Comparing Simple vs Extended protocol for pgx and pq drivers.

## Requirements

- Docker
- Make

## Run Test

```bash
make run
```

## Results

```
| Driver | Protocol | Bytes Read | Difference |
|--------|----------|------------|------------|
| pgx    | simple   | 17,747,491 | baseline   |
| pgx    | extended |  9,638,726 | -45.7%     |
| pq     | simple   | 17,786,878 | baseline   |
| pq     | extended | 17,795,080 | +0.05%     |
```

**Key finding:** pgx + extended protocol = 45.7% traffic reduction

## Other Commands

- `make up` - start PostgreSQL
- `make down` - stop PostgreSQL
- `make psql` - connect to database
- `make test` - run tests only
