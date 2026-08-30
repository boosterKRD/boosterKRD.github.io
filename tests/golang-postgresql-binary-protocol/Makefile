POSTGRES_USER := postgres
POSTGRES_PASSWORD := postgres
POSTGRES_DB := testdb
POSTGRES_PORT := 5432
CONTAINER_NAME := post1_postgres

.PHONY: up down restart psql logs clean setup build test test-docker run

up:
	docker run -d \
		--name $(CONTAINER_NAME) \
		-e POSTGRES_USER=$(POSTGRES_USER) \
		-e POSTGRES_PASSWORD=$(POSTGRES_PASSWORD) \
		-e POSTGRES_DB=$(POSTGRES_DB) \
		-p $(POSTGRES_PORT):5432 \
		postgres:latest

down:
	docker stop $(CONTAINER_NAME) || true
	docker rm $(CONTAINER_NAME) || true

restart: down up

psql:
	docker exec -it $(CONTAINER_NAME) psql -U $(POSTGRES_USER) -d $(POSTGRES_DB)

logs:
	docker logs -f $(CONTAINER_NAME)

clean: down
	docker volume prune -f

status:
	@docker ps -a | grep $(CONTAINER_NAME) || echo "not found"

setup:
	docker exec $(CONTAINER_NAME) psql -U $(POSTGRES_USER) -d $(POSTGRES_DB) -f /tmp/setup.sql || \
	docker exec -i $(CONTAINER_NAME) psql -U $(POSTGRES_USER) -d $(POSTGRES_DB) < setup.sql

setup-copy:
	docker cp setup.sql $(CONTAINER_NAME):/tmp/setup.sql
	docker exec $(CONTAINER_NAME) psql -U $(POSTGRES_USER) -d $(POSTGRES_DB) -f /tmp/setup.sql

build:
	cd go_pgx && go mod init go_pgx 2>/dev/null || true
	cd go_pgx && go get github.com/jackc/pgx/v5
	cd go_pgx && go build -o uuidtest .
	cd go_pq && go mod init go_pq 2>/dev/null || true
	cd go_pq && go get github.com/lib/pq
	cd go_pq && go build -o uuidtest .

test: test-docker

test-docker:
	docker build -f Dockerfile.test -t protocol-test .
	docker run --rm --network host protocol-test

all: up
	@sleep 5
	@$(MAKE) setup-copy
	@$(MAKE) build
	@$(MAKE) test

run: down
	@$(MAKE) up
	@sleep 5
	@$(MAKE) setup-copy
	@$(MAKE) test
