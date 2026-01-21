# MinIO AIStor - API Log Iceberg Integration Test

This test environment demonstrates MinIO AIStor's native Iceberg API log writer,
which writes API access logs directly to an Iceberg table without requiring Kafka.

## Architecture

```
MinIO Cluster (4 nodes)
        │
        ▼
  Internal API Logs
        │
        ▼
  Iceberg Table (Parquet files)
        │
        ▼
  Trino (SQL queries)
```

### Key Features

- **Native Iceberg**: No Kafka required - MinIO writes directly to Iceberg
- **Distributed**: Each node writes its logs, leader commits to Iceberg
- **Queryable**: Use Trino or any Iceberg-compatible query engine
- **Configurable**: Adjustable write and commit intervals

## Quick Start

### Prerequisites

- Docker and Docker Compose
- MinIO Client (`mc`) for generating traffic
- MinIO AIStor license

### Setup

1. **Configure environment**

   ```bash
   cp .env.sample .env
   # Edit .env and add your MINIO_LICENSE
   ```

2. **Start services**

   ```bash
   ./run.sh start
   ```

3. **Generate API traffic**

   ```bash
   ./run.sh generate --count 100
   ```

4. **Wait for logs to be committed**

   Default intervals: write every 30s, commit every 1m.
   Wait approximately 2 minutes for logs to appear.

5. **Query logs with Trino**

   ```bash
   docker exec -it trino trino

   # In Trino:
   USE api_logs.minio;
   SELECT COUNT(*) FROM api_logs;
   SELECT time, name, bucket, object FROM api_logs LIMIT 10;
   ```

## Commands

| Command                      | Description                             |
| ---------------------------- | --------------------------------------- |
| `./run.sh start`             | Start all services                      |
| `./run.sh stop`              | Stop all services                       |
| `./run.sh status`            | Show service status                     |
| `./run.sh logs -f`           | Follow service logs                     |
| `./run.sh generate --count N`| Generate N API operations               |
| `./run.sh continuous`        | Generate logs continuously (Ctrl+C)     |
| `./run.sh clean`             | Stop and remove all data                |

## Services

| Service        | URL                    | Credentials           |
| -------------- | ---------------------- | --------------------- |
| MinIO Console  | http://localhost:9001  | minioadmin/minioadmin |
| MinIO API      | http://localhost:9000  | minioadmin/minioadmin |
| Trino          | http://localhost:9999  | -                     |

## Configuration

### Environment Variables

| Variable                     | Default  | Description                          |
| ---------------------------- | -------- | ------------------------------------ |
| `MINIO_LICENSE`              | required | MinIO AIStor license key             |
| `ICEBERG_BUCKET`             | api-logs | Warehouse bucket for API logs        |
| `ICEBERG_NAMESPACE`          | minio    | Iceberg namespace                    |
| `ICEBERG_TABLE`              | api_logs | Iceberg table name                   |
| `ICEBERG_WRITE_INTERVAL`     | 30s      | How often to write Parquet files     |
| `ICEBERG_COMMIT_INTERVAL`    | 1m       | How often to commit to Iceberg       |
| `ICEBERG_BATCH_SIZE`         | 1000     | Records per Parquet file             |

### MinIO Environment Variables

These are set automatically in the docker-compose:

```
MINIO_LOG_API_INTERNAL_ENABLE=on
MINIO_LOG_API_INTERNAL_ICEBERG_ENABLE=on
MINIO_LOG_API_INTERNAL_ICEBERG_BUCKET=api-logs
MINIO_LOG_API_INTERNAL_ICEBERG_NAMESPACE=minio
MINIO_LOG_API_INTERNAL_ICEBERG_TABLE=api_logs
MINIO_LOG_API_INTERNAL_ICEBERG_WRITE_INTERVAL=30s
MINIO_LOG_API_INTERNAL_ICEBERG_COMMIT_INTERVAL=1m
```

## Querying API Logs

### With Trino

```sql
-- Connect to Trino
docker exec -it trino trino

-- List available catalogs (api_logs should be listed)
SHOW CATALOGS;

-- List schemas in the catalog
SHOW SCHEMAS FROM api_logs;

-- List tables in the namespace
SHOW TABLES FROM api_logs.minio;

-- Use the catalog
USE api_logs.minio;

-- Count all logs
SELECT COUNT(*) FROM api_logs;

-- View recent logs
SELECT time, name, bucket, object, httpStatusCode
FROM api_logs
ORDER BY time DESC
LIMIT 20;

-- API calls by type
SELECT name, COUNT(*) as cnt
FROM api_logs
GROUP BY name
ORDER BY cnt DESC;

-- Logs by time range
SELECT *
FROM api_logs
WHERE time > TIMESTAMP '2024-01-01 00:00:00'
LIMIT 100;

-- Error analysis
SELECT name, httpStatusCode, COUNT(*) as cnt
FROM api_logs
WHERE httpStatusCode >= 400
GROUP BY name, httpStatusCode
ORDER BY cnt DESC;
```

### Schema

The API logs table includes:

| Column              | Type      | Description                    |
| ------------------- | --------- | ------------------------------ |
| time                | timestamp | Request timestamp              |
| name                | string    | API operation name             |
| bucket              | string    | Target bucket                  |
| object              | string    | Target object key              |
| httpStatusCode      | int       | HTTP response status           |
| inputBytes          | long      | Request body size              |
| outputBytes         | long      | Response body size             |
| requestTime         | string    | Total request duration         |
| timeToFirstByte     | string    | Time to first response byte    |
| sourceHost          | string    | Client IP address              |
| userAgent           | string    | Client user agent              |
| accessKey           | string    | Access key used                |
| requestId           | string    | Unique request ID              |
| node                | string    | MinIO node that handled request|

## How It Works

1. **API Request**: Client makes S3 API call to MinIO
2. **Log Recording**: MinIO records the API call in memory
3. **Local Flush**: Periodically flushes to local disk (internal storage)
4. **Parquet Write**: Each node writes its logs to Parquet files
5. **Iceberg Commit**: Leader node commits Parquet files to Iceberg table
6. **Query**: Use Trino or other tools to query the Iceberg table

### Write Loop (per node)

- Runs on every MinIO node
- Reads local API logs since last checkpoint
- Writes them to Parquet files in the warehouse
- Creates index files for the commit loop

### Commit Loop (leader only)

- Uses distributed locking to elect leader
- Collects all pending Parquet files from all nodes
- Commits them atomically to the Iceberg table
- Cleans up index files after successful commit

## Troubleshooting

### Logs not appearing in Iceberg

1. Check MinIO logs for errors:
   ```bash
   ./run.sh logs -f
   ```

2. Verify the warehouse bucket exists:
   ```bash
   mc ls minio/api-logs/
   ```

3. Wait for the commit interval (default: 1 minute)

4. Check for pending files:
   ```bash
   mc ls minio/api-logs/.minio/api-logs-pending/
   ```

### Trino catalog not working

The Trino catalog is automatically created by the init container on startup.
If you need to recreate it manually, connect to Trino and run:

```sql
CREATE CATALOG api_logs USING iceberg WITH (
  "iceberg.catalog.type" = 'rest',
  "iceberg.rest-catalog.uri" = 'http://nginx:9000/_iceberg',
  "iceberg.rest-catalog.warehouse" = 'api-logs',
  "iceberg.rest-catalog.vended-credentials-enabled" = 'true',
  "iceberg.rest-catalog.security" = 'SIGV4',
  "iceberg.rest-catalog.signing-name" = 's3tables',
  "s3.region" = 'us-east-1',
  "s3.aws-access-key" = 'minioadmin',
  "s3.aws-secret-key" = 'minioadmin',
  "s3.endpoint" = 'http://nginx:9000',
  "s3.path-style-access" = 'true',
  "fs.hadoop.enabled" = 'false',
  "fs.native-s3.enabled" = 'true'
);
```

Key configuration points:
- **REST catalog URI**: `http://nginx:9000/_iceberg` - MinIO's built-in Iceberg REST API
- **Warehouse**: `api-logs` - the bucket name containing the Iceberg tables
- **Authentication**: SigV4 with signing-name `s3tables`

### mc not installed

Install the MinIO Client:

```bash
# Linux
wget https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x mc
sudo mv mc /usr/local/bin/

# macOS
brew install minio/stable/mc
```
