package main

import (
	"database/sql"
	"fmt"
	"log"
	"os"

	_ "github.com/lib/pq"
)

func main() {
	if len(os.Args) < 2 {
		log.Fatalf("Usage: %s [simple|extended]", os.Args[0])
	}
	mode := os.Args[1]

	connStr := "postgres://postgres:postgres@localhost:5432/testdb?sslmode=disable"

	if mode == "extended" {
		connStr += "&binary_parameters=yes"
		fmt.Println("PQ: Using EXTENDED protocol")
	} else if mode == "simple" {
		fmt.Println("PQ: Using SIMPLE protocol")
	} else {
		log.Fatalf("Invalid mode: %s", mode)
	}

	db, err := sql.Open("postgres", connStr)
	if err != nil {
		log.Fatalf("Failed to connect: %v", err)
	}
	defer db.Close()

	var rows *sql.Rows

	if mode == "extended" {
		rows, err = db.Query("SELECT id, user_id, created_at, updated_at, val_int, val_big, val_bool FROM test_data WHERE $1::int = $1", 1)
	} else {
		rows, err = db.Query("SELECT id, user_id, created_at, updated_at, val_int, val_big, val_bool FROM test_data")
	}

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
