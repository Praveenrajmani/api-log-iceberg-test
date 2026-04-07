# MinIO AIStor - API Log Iceberg Integration Test

This test environment demonstrates MinIO AIStor's native Iceberg API log writer,
which writes API access logs directly to an Iceberg table without requiring Kafka.

## Architecture

```
MinIO Cluster (4 nodes)
        │
        ▼
  In-Memory Buffer
        │
        ▼
  S3 Parquet Files (per node)
        │
        ▼
  Iceberg Table (leader commits)
        │
        ▼
  Trino (SQL queries)
```

### Key Features

- **Native Iceberg**: No Kafka required - MinIO writes directly to Iceberg
- **No Local Disk**: Logs flow from memory to S3 as Parquet files
- **Distributed**: Each node flushes its logs to S3, leader commits to Iceberg
- **Queryable**: Use Trino or any Iceberg-compatible query engine
- **Configurable**: Adjustable flush and commit intervals

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

   Default: flush every 10 records or 1m, commit every 3m.
   Wait approximately 5 minutes for logs to appear.

5. **Query logs with Trino**

   ```bash
   docker exec -it trino trino

   # In Trino:
   USE minio.logs;
   SELECT COUNT(*) FROM api;
   SELECT time, name, bucket, object FROM api LIMIT 10;
   ```

## Commands

| Command                       | Description                         |
| ----------------------------- | ----------------------------------- |
| `./run.sh start`              | Start all services                  |
| `./run.sh stop`               | Stop all services                   |
| `./run.sh status`             | Show service status                 |
| `./run.sh logs -f`            | Follow service logs                 |
| `./run.sh generate --count N` | Generate N API operations           |
| `./run.sh continuous`         | Generate logs continuously (Ctrl+C) |
| `./run.sh clean`              | Stop and remove all data            |

## Services

| Service       | URL                   | Credentials           |
| ------------- | --------------------- | --------------------- |
| MinIO Console | http://localhost:9001 | minioadmin/minioadmin |
| MinIO API     | http://localhost:9000 | minioadmin/minioadmin |
| Trino         | http://localhost:9999 | -                     |

## Configuration

### Environment Variables

| Variable                  | Default  | Description                         |
| ------------------------- | -------- | ----------------------------------- |
| `MINIO_LICENSE`           | required | MinIO AIStor license key            |
| `PARQUET_FLUSH_COUNT`     | 10       | Records before flushing to Parquet  |
| `PARQUET_FLUSH_INTERVAL`  | 1m       | Max time before flushing to Parquet |
| `ICEBERG_COMMIT_INTERVAL` | 3m       | How often to commit to Iceberg      |

API logs are stored in the system warehouse (`minio.logs.api`) automatically — no warehouse, namespace, or table configuration is needed.

### MinIO Environment Variables

These are set automatically in the docker-compose:

```
MINIO_LOG_API_INTERNAL_ENABLE=on
_MINIO_LOG_API_INTERNAL_PARQUET_FLUSH_COUNT=10
_MINIO_LOG_API_INTERNAL_PARQUET_FLUSH_INTERVAL=1m
_MINIO_LOG_API_INTERNAL_ICEBERG_COMMIT_INTERVAL=3m
```

## Querying API Logs

### With Trino

```sql
-- Connect to Trino
docker exec -it trino trino

-- List available catalogs (minio should be listed)
SHOW CATALOGS;

-- List schemas in the catalog
SHOW SCHEMAS FROM minio;

-- List tables in the logs namespace
SHOW TABLES FROM minio.logs;

-- Use the catalog
USE minio.logs;

-- Count all logs
SELECT COUNT(*) FROM api;

-- View recent logs
SELECT time, name, bucket, object, httpStatusCode
FROM api
ORDER BY time DESC
LIMIT 20;

-- API calls by type
SELECT name, COUNT(*) as cnt
FROM api
GROUP BY name
ORDER BY cnt DESC;

-- Logs by time range
SELECT *
FROM api
WHERE time > TIMESTAMP '2024-01-01 00:00:00'
LIMIT 100;

-- Error analysis
SELECT name, httpStatusCode, COUNT(*) as cnt
FROM api
WHERE httpStatusCode >= 400
GROUP BY name, httpStatusCode
ORDER BY cnt DESC;
```

### Schema

The API logs table includes:

| Column          | Type      | Description                     |
| --------------- | --------- | ------------------------------- |
| time            | timestamp | Request timestamp               |
| name            | string    | API operation name              |
| bucket          | string    | Target bucket                   |
| object          | string    | Target object key               |
| httpStatusCode  | int       | HTTP response status            |
| inputBytes      | long      | Request body size               |
| outputBytes     | long      | Response body size              |
| requestTime     | string    | Total request duration          |
| timeToFirstByte | string    | Time to first response byte     |
| sourceHost      | string    | Client IP address               |
| userAgent       | string    | Client user agent               |
| accessKey       | string    | Access key used                 |
| requestId       | string    | Unique request ID               |
| node            | string    | MinIO node that handled request |

## How It Works

1. **API Request**: Client makes S3 API call to MinIO
2. **Log Recording**: MinIO records the API call in an in-memory buffer
3. **Parquet Flush**: Each node flushes directly to S3 as Parquet files (on count or interval)
4. **Index Marker**: A 0-byte index marker is created for each Parquet file
5. **Iceberg Commit**: Leader node commits pending Parquet files to the Iceberg table
6. **Query**: Use Trino or other tools to query the Iceberg table

### Flush (per node)

- Runs on every MinIO node
- Buffers API logs in memory
- Flushes to S3 as Parquet files when count threshold or time interval is reached
- Creates 0-byte index markers for the commit loop to discover

### Commit Loop (leader only)

- Uses distributed locking to elect leader
- Lists all pending index markers from all nodes
- Commits referenced Parquet files atomically to the Iceberg table
- Cleans up index markers after successful commit

## Troubleshooting

### Logs not appearing in Iceberg

1. Check MinIO logs for errors:

   ```bash
   ./run.sh logs -f
   ```

2. API logs are stored in `.minio.sys` (system bucket, not directly browsable).
   Wait for the commit interval (default: 3 minutes for this test setup).

3. Check Trino for committed data:
   ```sql
   USE minio.logs;
   SELECT COUNT(*) FROM api;
   ```

### Trino catalog not working

The Trino catalog is automatically created by the init container on startup.
If you need to recreate it manually, connect to Trino and run:

```sql
CREATE CATALOG minio USING iceberg WITH (
  "iceberg.catalog.type" = 'rest',
  "iceberg.rest-catalog.uri" = 'http://nginx:9000/_iceberg',
  "iceberg.rest-catalog.warehouse" = 'minio',
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
- **Warehouse**: `minio` - the system warehouse for API logs
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
