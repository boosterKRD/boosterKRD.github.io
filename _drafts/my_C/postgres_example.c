#include <stdio.h>  // Print  
#include <stdlib.h> // Malloc and free
#include "/Users/maratbogatyrev/Documents/repo/BoosterKRD/postgres/src/interfaces/libpq/libpq-fe.h" // Include the PostgreSQL library header

// Function to connect to the PostgreSQL database
PGconn* connect_to_db(const char *conninfo) {
    PGconn *conn = PQconnectdb(conninfo);
    if (PQstatus(conn) != CONNECTION_OK) {
        fprintf(stderr, "Connection to database failed: %s", PQerrorMessage(conn));
        PQfinish(conn);
        return NULL;
    }
    return conn;
}

// Function to execute a query and return the result
PGresult* execute_query(PGconn *conn, const char *query) {
    PGresult *res = PQexec(conn, query);
    if (PQresultStatus(res) != PGRES_TUPLES_OK) {
        fprintf(stderr, "Query execution failed: %s", PQerrorMessage(conn));
        PQclear(res);
        return NULL;
    }
    return res;
}

// Function to process the result of a query
void process_result(PGresult *res) {
    for (int i = 0; i < PQntuples(res); i++) {
        printf("Result: %s\n", PQgetvalue(res, i, 0)); // Print the first column of each row
    }
}

int main() {
    int age = 25;
    float height = 1.75;
    char initial = 'M';
    int *year_of_born = malloc(sizeof(int)); // Allocate memory for an int

    printf("Age: %d\n", age);
    printf("Height: %.2f\n", height);
    printf("Initial: %c\n", initial);
    printf("Hello, World2!\n");

    if (year_of_born == NULL) {
        printf("Memory allocation failed\n");
        return 1; // Exit if allocation fails
    }    
    // Assign values
    *year_of_born = 1982; // Use dereferencing to assign value    
    printf("Age: %d\n", *year_of_born);    

    // Free allocated memory
    free(year_of_born);
    
    // Connection string: change these parameters as needed
    const char *conninfo = "dbname=your_db_name user=your_username password=your_password host=localhost port=5432";

    // Connect to the database
    PGconn *conn = connect_to_db(conninfo);
    if (conn == NULL) {
        return 1; // Exit if connection failed
    }

    // Execute the query
    PGresult *res = execute_query(conn, "SELECT 1;");
    if (res == NULL) {
        PQfinish(conn); // Close the connection if query failed
        return 1;
    }

    // Process the result
    process_result(res);

    // Clean up
    PQclear(res);
    PQfinish(conn); // Close the connection
    
    return 0;
}