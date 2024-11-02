#!/bin/bash

# Variables for connecting to the database
DB_HOST="my-postgres-db.ch4ssweuqhqv.eu-north-1.rds.amazonaws.com"
DB_USER="user_test1"
DB_NAME="postgres"
DB_PASSWORD="wolf"
CONNECTION_TIMEOUT=1  # Timeout for connection in seconds
QUERY_TIMEOUT=1  # Timeout for SQL query execution

# Setting environment variables for the password and connection timeout
export PGPASSWORD=$DB_PASSWORD
export PGCONNECT_TIMEOUT=$CONNECTION_TIMEOUT

# Function to create the table if it doesn't exist
create_table_if_not_exists() {
  echo "$(date): Checking if table 'test' exists..."
  
  result=$(timeout $QUERY_TIMEOUT psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -c "CREATE TABLE IF NOT EXISTS test (id serial PRIMARY KEY, name VARCHAR(255));" 2>&1)
  
  # Check if table creation was successful
  if [ $? -eq 0 ]; then
    echo "$(date): Table 'test' is ready."
  else
    echo "$(date): Error while checking/creating the table 'test'."
    echo "Error: $result"
  fi
}

# Function to resolve IP and perform INSERT
run_insert() {
  echo "$(date): Resolving IP address for $DB_HOST..."

  # Resolve IP address with a 1-second timeout and filter for valid IPv4 addresses
  DB_IP=$(timeout 1 dig +short $DB_HOST | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)

  # Check if IP resolution was successful
  if [ -z "$DB_IP" ]; then
    echo "$(date): Failed to resolve IP for $DB_HOST"
  else
    echo "$(date): IP resolved: $DB_IP for $DB_HOST"
    local name="Test_$(date +%s)_$DB_IP"
    echo "$(date): Inserting data: $name"
    
    result=$(timeout $QUERY_TIMEOUT psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -c "INSERT INTO test (name) VALUES ('$name');" 2>&1)

    # Check if the data was successfully inserted
    if [ $? -eq 0 ]; then
      echo "$(date): Successfully inserted: $name"
    else
      echo "$(date): Error during insertion: $name"
      echo "Error: $result"
    fi
  fi
}

# Create the table if it doesn't exist
create_table_if_not_exists

# Infinite loop to insert data
while true; do
  echo "==========================="
  echo "$(date): Starting a new data insertion iteration"
  run_insert
  sleep 1  # 1-second delay between insertions
done