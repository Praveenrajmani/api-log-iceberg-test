#!/bin/bash
#
# Generate API logs for MinIO AIStor by performing S3 operations
# Usage: ./generate-api-logs.sh [alias] [--count N]
#

set -e

ALIAS="minio"
COUNT=100

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --count|-n)
            COUNT="$2"
            shift 2
            ;;
        -*)
            echo "Unknown option: $1"
            echo "Usage: $0 [alias] [--count N]"
            echo "Example: $0 minio --count 500"
            exit 1
            ;;
        *)
            ALIAS="$1"
            shift
            ;;
    esac
done

# Validate count is a positive integer
if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [ "$COUNT" -le 0 ]; then
    echo "Error: --count must be a positive integer"
    exit 1
fi

# Check if mc is available
if ! command -v mc &> /dev/null; then
    echo "Error: mc command not found. Please install MinIO Client."
    echo "See: https://min.io/docs/minio/linux/reference/minio-mc.html"
    exit 1
fi

# Check if alias exists
if ! mc alias list "$ALIAS" &> /dev/null 2>&1; then
    echo "Error: Alias '$ALIAS' not found. Please set up the alias first."
    echo "Example: mc alias set $ALIAS http://localhost:9000 minioadmin minioadmin"
    exit 1
fi

echo "Generating API logs for alias: $ALIAS"
echo "============================================"
echo "Target operations: $COUNT"
echo "============================================"
echo ""

# Create test bucket
BUCKET="test-api-logs-$(date +%s)"
echo "Creating test bucket: $BUCKET..."
mc mb "$ALIAS/$BUCKET" > /dev/null 2>&1 || true

# Upload initial test object
echo "Uploading initial test object..."
echo "test data $(date)" | mc pipe "$ALIAS/$BUCKET/test-object.txt" > /dev/null 2>&1 || true

# Generate API calls with weighted distribution
COUNTER=0
START_TIME=$(date +%s)

echo "Generating $COUNT API operations..."
echo ""

for ((i=1; i<=COUNT; i++)); do
    # Select random operation based on weighted distribution:
    # - List objects: 30%
    # - Get object: 25%
    # - Head object: 20%
    # - Put object: 10%
    # - Copy object: 5%
    # - Delete object: 5%
    # - List buckets: 2%
    # - Get tags: 2%
    # - Stat object: 1%
    OP_INDEX=$((RANDOM % 100))

    if [ $OP_INDEX -lt 30 ]; then
        # List objects (30%)
        mc ls "$ALIAS/$BUCKET" > /dev/null 2>&1 || true
    elif [ $OP_INDEX -lt 55 ]; then
        # Get object (25%)
        mc cat "$ALIAS/$BUCKET/test-object.txt" > /dev/null 2>&1 || true
    elif [ $OP_INDEX -lt 75 ]; then
        # Head object (20%)
        mc stat "$ALIAS/$BUCKET/test-object.txt" > /dev/null 2>&1 || true
    elif [ $OP_INDEX -lt 85 ]; then
        # Put object (10%)
        OBJ_NAME="object-$RANDOM.txt"
        echo "data-$i" | mc pipe "$ALIAS/$BUCKET/$OBJ_NAME" > /dev/null 2>&1 || true
    elif [ $OP_INDEX -lt 90 ]; then
        # Copy object (5%)
        COPY_NAME="copy-$RANDOM.txt"
        mc cp "$ALIAS/$BUCKET/test-object.txt" "$ALIAS/$BUCKET/$COPY_NAME" > /dev/null 2>&1 || true
    elif [ $OP_INDEX -lt 95 ]; then
        # Delete object (5%)
        OBJECTS=($(mc ls "$ALIAS/$BUCKET" 2>/dev/null | awk '{print $NF}' | grep -E "^object-|^copy-" | head -5))
        if [ ${#OBJECTS[@]} -gt 0 ]; then
            TARGET="${OBJECTS[$RANDOM % ${#OBJECTS[@]}]}"
            mc rm "$ALIAS/$BUCKET/$TARGET" > /dev/null 2>&1 || true
        fi
    elif [ $OP_INDEX -lt 97 ]; then
        # List buckets (2%)
        mc ls "$ALIAS" > /dev/null 2>&1 || true
    elif [ $OP_INDEX -lt 99 ]; then
        # Get tags (2%)
        mc tag list "$ALIAS/$BUCKET/test-object.txt" > /dev/null 2>&1 || true
    else
        # Stat object (1%)
        mc stat "$ALIAS/$BUCKET/test-object.txt" > /dev/null 2>&1 || true
    fi

    COUNTER=$((COUNTER + 1))

    # Progress update every 10% or every 100 operations (whichever is smaller)
    UPDATE_INTERVAL=$((COUNT / 10))
    if [ $UPDATE_INTERVAL -gt 100 ]; then
        UPDATE_INTERVAL=100
    fi
    if [ $UPDATE_INTERVAL -lt 1 ]; then
        UPDATE_INTERVAL=1
    fi

    if [ $((COUNTER % UPDATE_INTERVAL)) -eq 0 ]; then
        ELAPSED=$(($(date +%s) - START_TIME))
        PERCENT=$((COUNTER * 100 / COUNT))
        if [ $ELAPSED -gt 0 ]; then
            OPS_PER_SEC=$((COUNTER / ELAPSED))
        else
            OPS_PER_SEC=$COUNTER
        fi
        echo "Progress: $COUNTER/$COUNT ($PERCENT%) - $OPS_PER_SEC ops/sec"
    fi
done

TOTAL_TIME=$(($(date +%s) - START_TIME))
if [ $TOTAL_TIME -gt 0 ]; then
    AVG_OPS_PER_SEC=$((COUNT / TOTAL_TIME))
else
    AVG_OPS_PER_SEC=$COUNT
fi

echo ""
echo "Cleanup: Removing test bucket and objects..."
mc rm --recursive --force "$ALIAS/$BUCKET" > /dev/null 2>&1 || true
mc rb "$ALIAS/$BUCKET" > /dev/null 2>&1 || true

echo ""
echo "============================================"
echo "API log generation complete!"
echo "============================================"
echo "Total operations: $COUNT"
echo "Total time: ${TOTAL_TIME}s"
echo "Average throughput: $AVG_OPS_PER_SEC ops/sec"
echo ""
echo "API logs will be written to the Iceberg table after the write/commit intervals."
echo "Default: write every 30s, commit every 1m"
