import psycopg2
import subprocess
import time
import datetime

# Configuration for connecting to the database
DB_HOST = "maratos.ch4ssweuqhqv.eu-north-1.rds.amazonaws.com"
DB_USER = "marat"
DB_NAME = "postgres"
DB_PASSWORD = "wolfik25"
CONNECTION_TIMEOUT = 1  # Connection timeout in seconds
MAX_RETRIES = 3  # Maximum number of connection attempts

# Keepalive settings
KEEPALIVES_IDLE = 3
KEEPALIVES_INTERVAL = 1
KEEPALIVES_COUNT = 2

def resolve_ip(host):
    try:
        result = subprocess.run(
            ["timeout", str(CONNECTION_TIMEOUT), "dig", "+short", host],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        ip_list = result.stdout.decode().splitlines()
        return next((ip for ip in ip_list if ip.count('.') == 3), None)
    except subprocess.TimeoutExpired:
        print(f"{datetime.datetime.now()}: Timeout while resolving IP for {host}")
        return None
    except Exception as e:
        print(f"{datetime.datetime.now()}: Error: {e}")
        return None

def insert_and_fetch(db_ip):
    name = f"Test_{int(time.time())}_{db_ip}"
    print(f"{datetime.datetime.now()}: Inserting data: {name}")

    conn = None  # Initialize conn to None
    for attempt in range(MAX_RETRIES):
        try:
            conn = psycopg2.connect(
                host=DB_HOST,
                user=DB_USER,
                dbname=DB_NAME,
                password=DB_PASSWORD,
                connect_timeout=CONNECTION_TIMEOUT
            )
            cur = conn.cursor()

            # Perform INSERT
            cur.execute("INSERT INTO test (name) VALUES (%s);", (name,))

            # Perform additional queries
            cur.execute("SELECT setting AS max_conn FROM pg_settings WHERE name = 'max_connections';")
            max_conn = cur.fetchone()[0]

            cur.execute("SELECT COUNT(*) AS num_connection FROM pg_stat_activity WHERE client_addr IS NOT NULL;")
            num_connection = cur.fetchone()[0]

            print(f"{datetime.datetime.now()}: {name} | max_conn: {max_conn} | num_connection: {num_connection}")

            conn.commit()
            cur.close()
            return  # Terminate on success

        except psycopg2.OperationalError as e:
            print(f"{datetime.datetime.now()}: Database connection error: {e}.")
            time.sleep(2)  # Delay before retrying
        except Exception as e:
            print(f"{datetime.datetime.now()}: Error during insertion: {name}")
            print(f"Error: {e}")
        finally:
            if conn:
                conn.close()
                print(f"{datetime.datetime.now()}: Connection closed.")

# Infinite loop for inserting data
while True:
    print("===========================")
    
    db_ip = resolve_ip(DB_HOST)

    if not db_ip:
        print(f"{datetime.datetime.now()}: Failed to resolve IP for {DB_HOST}")
        time.sleep(1)  # 1-second delay before the next attempt
        continue

    insert_and_fetch(db_ip)
    print("===========================")
    time.sleep(1)  # 1-second delay between insertions