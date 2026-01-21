#!/bin/bash
#
# API Log Iceberg Integration Test
# One-click setup for testing MinIO native Iceberg API logging
#

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

print_banner() {
    echo -e "${CYAN}"
    cat << 'EOF'
    ╔═══════════════════════════════════════════════════════════════╗
    ║     MinIO AIStor - API Log Iceberg Integration Test           ║
    ║     Native Iceberg table for API access logs                  ║
    ╚═══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_msg() {
    local color=$1
    local msg=$2
    echo -e "${color}${msg}${NC}"
}

usage() {
    cat << EOF
MinIO AIStor - API Log Iceberg Integration Test

Tests the native Iceberg API log writer where MinIO writes API access logs
directly to an Iceberg table without requiring Kafka.

ARCHITECTURE:
  MinIO Cluster (4-node) → Internal API Logs → Iceberg Table → Trino (query)
        ↓
      nginx
   :9000/:9001

USAGE:
  $0 [command] [options]

COMMANDS:
  start           Start all services (default)
  stop            Stop all services
  status          Show status of all services
  logs            Show logs (use -f for follow)
  generate        Generate API logs
  continuous      Generate logs continuously (Ctrl+C to stop)
  restart         Restart all services
  clean           Stop and remove all data

SERVICES:
  MinIO API:       http://localhost:9000
  MinIO Console:   http://localhost:9001
  Trino:           http://localhost:9999

ICEBERG TABLE:
  Warehouse:       api-logs (configurable)
  Namespace:       minio
  Table:           api_logs

OPTIONS:
  -h, --help      Show this help message

EXAMPLES:
  # Start everything
  $0 start

  # Check status
  $0 status

  # Generate API logs
  $0 generate --count 100

  # Continuous log generation (Ctrl+C to stop)
  $0 continuous

  # Query logs in Trino
  docker exec -it trino trino --execute 'SELECT * FROM minio_iceberg.minio.api_logs LIMIT 10'

  # View logs
  $0 logs -f

  # Stop services
  $0 stop

  # Clean everything
  $0 clean

EOF
    exit 0
}

# Load configuration from .env
load_config() {
    if [ -f "${SCRIPT_DIR}/.env" ]; then
        print_msg "$YELLOW" "Loading configuration from ${SCRIPT_DIR}/.env..."
        set -a
        source "${SCRIPT_DIR}/.env"
        set +a
    fi

    # Check if license is set
    if [ -z "$MINIO_LICENSE" ]; then
        print_msg "$RED" "Error: MINIO_LICENSE not set"
        print_msg "$YELLOW" "Please set MINIO_LICENSE in ${SCRIPT_DIR}/.env or export it"
        print_msg "$YELLOW" "  cp .env.sample .env"
        print_msg "$YELLOW" "  # Edit .env and add your license key"
        exit 1
    fi
}

# Start services
start_services() {
    print_banner
    load_config

    print_header "Starting Services"

    cd "$SCRIPT_DIR"

    # Export for docker-compose
    export MINIO_LICENSE

    print_msg "$YELLOW" "Starting MinIO cluster..."
    docker compose up -d minio1 minio2 minio3 minio4

    print_msg "$YELLOW" "Starting nginx load balancer..."
    docker compose up -d nginx

    print_msg "$YELLOW" "Waiting for MinIO cluster to be ready..."
    for i in {1..30}; do
        if curl -sf http://localhost:9000/minio/health/live >/dev/null 2>&1; then
            print_msg "$GREEN" "✓ MinIO cluster is ready"
            break
        fi
        sleep 2
    done

    print_msg "$YELLOW" "Starting Trino..."
    docker compose up -d trino

    print_msg "$YELLOW" "Waiting for Trino to be ready..."
    for i in {1..30}; do
        if curl -sf http://localhost:9999/v1/status >/dev/null 2>&1; then
            print_msg "$GREEN" "✓ Trino is ready"
            break
        fi
        sleep 2
    done

    print_msg "$YELLOW" "Running initialization..."
    docker compose up init

    print_header "All Services Started!"

    echo -e "${GREEN}"
    cat << 'EOF'
    ┌─────────────────────────────────────────────────────────────────┐
    │                    SERVICES READY                               │
    ├─────────────────────────────────────────────────────────────────┤
    │                                                                 │
    │  MinIO:                                                         │
    │    • Console:            http://localhost:9001                  │
    │    • API:                http://localhost:9000                  │
    │                                                                 │
    │  Trino:                  http://localhost:9999                  │
    │                                                                 │
    │  Credentials:            minioadmin / minioadmin                │
    │                                                                 │
    │  Iceberg Table:                                                 │
    │    • Warehouse:          api-logs                               │
    │    • Namespace:          minio                                  │
    │    • Table:              api_logs                               │
    │                                                                 │
    └─────────────────────────────────────────────────────────────────┘
EOF
    echo -e "${NC}"

    print_msg "$CYAN" "Quick start:"
    echo "  # Generate API logs"
    echo "  $0 generate --count 100"
    echo ""
    echo "  # Wait for logs to be committed (default: ~2 minutes)"
    echo ""
    echo "  # Query logs in Trino"
    echo "  docker exec -it trino trino --execute 'SELECT * FROM minio_iceberg.minio.api_logs LIMIT 10'"
    echo ""
    print_msg "$CYAN" "Other commands:"
    echo "  $0 status              - Check service status"
    echo "  $0 logs -f             - View logs"
    echo "  $0 continuous          - Generate logs continuously"
    echo "  $0 stop                - Stop all services"
}

# Stop services
stop_services() {
    print_header "Stopping Services"
    cd "$SCRIPT_DIR"
    docker compose down
    print_msg "$GREEN" "✓ All services stopped"
}

# Clean everything
clean_services() {
    print_header "Cleaning Up"
    cd "$SCRIPT_DIR"
    docker compose down -v --remove-orphans
    print_msg "$GREEN" "✓ All services stopped and volumes removed"
}

# Show status
show_status() {
    print_header "Service Status"
    cd "$SCRIPT_DIR"
    docker compose ps

    echo ""
    print_msg "$CYAN" "MinIO Health:"
    if curl -sf http://localhost:9000/minio/health/live >/dev/null 2>&1; then
        print_msg "$GREEN" "  ✓ MinIO API is healthy"
    else
        print_msg "$RED" "  ✗ MinIO API is not responding"
    fi

    print_msg "$CYAN" "Trino Health:"
    if curl -sf http://localhost:9999/v1/status >/dev/null 2>&1; then
        print_msg "$GREEN" "  ✓ Trino is healthy"
    else
        print_msg "$RED" "  ✗ Trino is not responding"
    fi
}

# Show logs
show_logs() {
    cd "$SCRIPT_DIR"
    docker compose logs "$@"
}

# Generate API logs
generate_logs() {
    local count=100

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --count|-n)
                count="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    print_header "Generating API Logs"

    # Check if mc is available
    if ! command -v mc &> /dev/null; then
        print_msg "$RED" "Error: mc (MinIO Client) is not installed."
        print_msg "$YELLOW" "Please install mc: https://min.io/docs/minio/linux/reference/minio-mc.html"
        exit 1
    fi

    # Generate unique alias name
    local UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "$$-$(date +%s)")
    local ALIAS="minio-${UUID:0:8}"

    # Setup mc alias
    print_msg "$YELLOW" "Setting up temporary mc alias: $ALIAS"
    mc alias set "$ALIAS" http://localhost:9000 minioadmin minioadmin > /dev/null 2>&1

    # Cleanup function
    cleanup_alias() {
        print_msg "$YELLOW" "Cleaning up temporary alias: $ALIAS"
        mc alias rm "$ALIAS" > /dev/null 2>&1 || true
    }
    trap cleanup_alias EXIT INT TERM

    # Run the generate script
    "$SCRIPT_DIR/generate/generate-api-logs.sh" "$ALIAS" --count "$count"

    print_msg "$GREEN" "✓ API log generation complete!"
    print_msg "$CYAN" ""
    print_msg "$CYAN" "Logs will be written to the Iceberg table after:"
    print_msg "$CYAN" "  - Write interval: ${ICEBERG_WRITE_INTERVAL:-30s}"
    print_msg "$CYAN" "  - Commit interval: ${ICEBERG_COMMIT_INTERVAL:-1m}"
    print_msg "$CYAN" ""
    print_msg "$CYAN" "Query logs with Trino:"
    echo "  docker exec -it trino trino --execute 'SELECT COUNT(*) FROM minio_iceberg.minio.api_logs'"
}

# Generate logs continuously
generate_logs_continuous() {
    local interval=5
    local batch_size=20

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --interval|-i)
                interval="$2"
                shift 2
                ;;
            --batch|-b)
                batch_size="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    print_header "Continuous Log Generation Mode"

    # Check if mc is available
    if ! command -v mc &> /dev/null; then
        print_msg "$RED" "Error: mc (MinIO Client) is not installed."
        print_msg "$YELLOW" "Please install mc: https://min.io/docs/minio/linux/reference/minio-mc.html"
        exit 1
    fi

    # Check if MinIO is running
    if ! curl -sf http://localhost:9000/minio/health/live >/dev/null 2>&1; then
        print_msg "$RED" "Error: MinIO is not running on port 9000"
        exit 1
    fi

    # Setup mc alias
    local UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "$$-$(date +%s)")
    local ALIAS="minio-${UUID:0:8}"
    mc alias set "$ALIAS" http://localhost:9000 minioadmin minioadmin > /dev/null 2>&1

    # Cleanup function
    cleanup_alias() {
        echo ""
        print_msg "$YELLOW" "Stopping continuous log generation..."
        print_msg "$YELLOW" "Cleaning up temporary alias: $ALIAS"
        mc alias rm "$ALIAS" > /dev/null 2>&1 || true
        exit 0
    }
    trap cleanup_alias EXIT INT TERM

    print_msg "$YELLOW" "Generating logs continuously..."
    print_msg "$CYAN" "  Interval: ${interval}s between batches"
    print_msg "$CYAN" "  Batch size: ${batch_size} operations per batch"
    print_msg "$CYAN" ""
    print_msg "$GREEN" "Press Ctrl+C to stop"
    print_msg "$CYAN" ""

    # Create test bucket
    local BUCKET="continuous-logs-$(date +%s)"
    mc mb "$ALIAS/$BUCKET" > /dev/null 2>&1 || true

    local iteration=0
    local total_ops=0

    while true; do
        iteration=$((iteration + 1))
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

        # Perform operations
        for ((j=1; j<=batch_size; j++)); do
            OBJ_NAME="iter-${iteration}-obj-${j}.txt"
            echo "data-$iteration-$j at $timestamp" | mc pipe "$ALIAS/$BUCKET/$OBJ_NAME" > /dev/null 2>&1 || true
            total_ops=$((total_ops + 1))
        done

        # List to generate more logs
        mc ls "$ALIAS/$BUCKET" > /dev/null 2>&1 || true
        total_ops=$((total_ops + 1))

        printf "\r[%s] Iteration %d: %d total operations" "$timestamp" "$iteration" "$total_ops"

        sleep "$interval"
    done
}

# Main command router
case "${1:-start}" in
    start)
        start_services
        ;;
    stop)
        stop_services
        ;;
    status)
        show_status
        ;;
    logs)
        shift
        show_logs "$@"
        ;;
    generate)
        shift
        generate_logs "$@"
        ;;
    continuous)
        shift
        generate_logs_continuous "$@"
        ;;
    restart)
        stop_services
        start_services
        ;;
    clean)
        clean_services
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        print_msg "$RED" "Unknown command: $1"
        echo ""
        usage
        ;;
esac
