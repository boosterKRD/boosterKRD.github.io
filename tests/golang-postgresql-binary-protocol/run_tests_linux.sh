#!/bin/sh

echo "=== Building ==="
cd /test/go_pgx && go mod init go_pgx && go mod tidy && go build -o uuidtest .
cd /test/go_pq && go mod init go_pq && go mod tidy && go build -o uuidtest .

echo ""
echo "=== Running tests ==="

# Store results
pgx_simple_bytes=""
pgx_extended_bytes=""
pq_simple_bytes=""
pq_extended_bytes=""

for driver in pgx pq; do
    for mode in simple extended; do
        echo "Testing: ${driver} ${mode}"

        # Run with strace
        strace -f -e trace=read,write /test/go_${driver}/uuidtest ${mode} 2>&1 | tee /tmp/${driver}_${mode}.log > /dev/null

        # Calculate total bytes read
        read_bytes=$(grep 'read(' /tmp/${driver}_${mode}.log | grep -oE '= [0-9]+$' | cut -d' ' -f2 | awk '{sum+=$1} END {print sum+0}')

        # Store result
        case "${driver}_${mode}" in
            pgx_simple) pgx_simple_bytes=$read_bytes ;;
            pgx_extended) pgx_extended_bytes=$read_bytes ;;
            pq_simple) pq_simple_bytes=$read_bytes ;;
            pq_extended) pq_extended_bytes=$read_bytes ;;
        esac

        echo "${driver} ${mode}: ${read_bytes} bytes"
        echo ""
    done
done

echo "=== RESULTS ==="
echo "| Driver | Protocol | Bytes Read |"
echo "|--------|----------|------------|"
echo "| pgx | simple | ${pgx_simple_bytes} |"
echo "| pgx | extended | ${pgx_extended_bytes} |"
echo "| pq | simple | ${pq_simple_bytes} |"
echo "| pq | extended | ${pq_extended_bytes} |"
