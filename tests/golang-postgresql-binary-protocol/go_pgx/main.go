package main

import (
	"context"
	"fmt"
	"log"
	"os"

	"github.com/jackc/pgx/v5"
)

func main() {
	if len(os.Args) < 2 {
		log.Fatalf("Usage: %s [simple|extended]", os.Args[0])
	}
	mode := os.Args[1]

	ctx := context.Background()
	url := "postgres://postgres:postgres@localhost:5432/testdb?sslmode=disable"

	config, err := pgx.ParseConfig(url)
	if err != nil {
		log.Fatalf("ParseConfig error: %v", err)
	}

	switch mode {
	case "simple":
		config.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol
		fmt.Println("PGX: Using SIMPLE protocol")
	case "extended":
		config.DefaultQueryExecMode = pgx.QueryExecModeCacheStatement
		fmt.Println("PGX: Using EXTENDED protocol")
	default:
		log.Fatalf("Invalid mode: %s", mode)
	}

	conn, err := pgx.ConnectConfig(ctx, config)
	if err != nil {
		log.Fatalf("Connect failed: %v", err)
	}
	defer conn.Close(ctx)

	rows, err := conn.Query(ctx, "SELECT id, user_id, created_at, updated_at, val_int, val_big, val_bool FROM test_data")
	if err != nil {
		log.Fatalf("Query failed: %v", err)
	}
	defer rows.Close()

	var count int
	for rows.Next() {
		var (
			id        string
			userID    string
			createdAt string
			updatedAt string
			valInt    int
			valBig    int64
			valBool   bool
		)
		if err := rows.Scan(&id, &userID, &createdAt, &updatedAt, &valInt, &valBig, &valBool); err != nil {
			log.Fatalf("Scan failed: %v", err)
		}
		count++
	}

	fmt.Printf("Fetched %d rows\n", count)
}
