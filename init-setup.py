#!/usr/bin/env python3
"""
API Log Iceberg Integration Test - Initialization Script

This script:
1. Waits for MinIO cluster to be ready
2. Sets up Trino catalog to query the Iceberg table
3. Prints instructions for generating API logs and querying

The warehouse bucket is automatically created by MinIO when Iceberg logging is enabled.
"""

import json
import os
import sys
import time

import requests

# =============================================================================
# Configuration from environment
# =============================================================================
MINIO_ENDPOINT = os.getenv("MINIO_ENDPOINT", "http://nginx:9000")
ACCESS_KEY = os.getenv("MINIO_ACCESS_KEY", "minioadmin")
SECRET_KEY = os.getenv("MINIO_SECRET_KEY", "minioadmin")
WAREHOUSE_BUCKET = os.getenv("WAREHOUSE_BUCKET", "api-logs")
NAMESPACE = os.getenv("NAMESPACE", "minio")
TABLE_NAME = os.getenv("TABLE_NAME", "api_logs")
TRINO_HOST = os.getenv("TRINO_HOST", "trino")
TRINO_PORT = int(os.getenv("TRINO_PORT", "8080"))


def log(msg):
    """Print with timestamp prefix."""
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def wait_for_minio():
    """Wait for MinIO to be healthy."""
    log("Waiting for MinIO cluster to be ready...")
    for i in range(60):
        try:
            resp = requests.get(f"{MINIO_ENDPOINT}/minio/health/live", timeout=5)
            if resp.status_code == 200:
                log("MinIO cluster is ready")
                return True
        except Exception:
            pass
        time.sleep(2)
    log("Warning: MinIO health check timed out")
    return False


def setup_trino_catalog():
    """Create a Trino catalog for the MinIO Iceberg REST catalog using SQL."""
    import trino

    log("Setting up Trino catalog...")

    catalog_name = WAREHOUSE_BUCKET.replace("-", "_")  # Trino catalog names can't have hyphens

    try:
        conn = trino.dbapi.connect(
            host=TRINO_HOST,
            port=TRINO_PORT,
            user="trino",
        )
        cursor = conn.cursor()

        # Create dynamic Iceberg catalog pointing to MinIO's Iceberg REST API
        create_catalog_sql = f"""
            CREATE CATALOG {catalog_name} USING iceberg
            WITH (
                "iceberg.catalog.type" = 'rest',
                "iceberg.rest-catalog.uri" = '{MINIO_ENDPOINT}/_iceberg',
                "iceberg.rest-catalog.warehouse" = '{WAREHOUSE_BUCKET}',
                "iceberg.rest-catalog.vended-credentials-enabled" = 'true',
                "iceberg.rest-catalog.security" = 'SIGV4',
                "iceberg.rest-catalog.signing-name" = 's3tables',
                "s3.region" = 'us-east-1',
                "s3.aws-access-key" = '{ACCESS_KEY}',
                "s3.aws-secret-key" = '{SECRET_KEY}',
                "s3.endpoint" = '{MINIO_ENDPOINT}',
                "s3.path-style-access" = 'true',
                "fs.hadoop.enabled" = 'false',
                "fs.native-s3.enabled" = 'true'
            )
        """

        log(f"Creating Trino catalog: {catalog_name}")
        cursor.execute(create_catalog_sql)
        log(f"Trino catalog '{catalog_name}' created successfully")

        # Verify the catalog by listing schemas
        cursor.execute(f"SHOW SCHEMAS FROM {catalog_name}")
        schemas = cursor.fetchall()
        log(f"Available schemas in {catalog_name}: {[s[0] for s in schemas]}")

        cursor.close()
        conn.close()

    except Exception as e:
        error_msg = str(e)
        if "already exists" in error_msg.lower():
            log(f"Trino catalog '{catalog_name}' already exists")
        else:
            log(f"Warning: Could not create Trino catalog: {e}")
            log("You may need to create the catalog manually")

    return catalog_name


def print_instructions(catalog_name):
    """Print instructions for generating traffic and querying."""
    print("\n" + "=" * 70)
    print("SETUP COMPLETE")
    print("=" * 70)
    print(f"""
The MinIO cluster is configured to write API logs to an Iceberg table.
Logs will be written to: {WAREHOUSE_BUCKET}/{NAMESPACE}/{TABLE_NAME}

CONFIGURATION:
  - Write interval: logs are batched and written to Parquet files periodically
  - Commit interval: Parquet files are committed to Iceberg periodically
  - Both intervals are configurable via environment variables

STEP 1: Generate API Traffic
============================
Use the mc client to generate API traffic that will be logged:

  # Install mc if not already installed
  # https://min.io/docs/minio/linux/reference/minio-mc.html

  # Set up alias
  mc alias set minio http://localhost:9000 {ACCESS_KEY} {SECRET_KEY}

  # Create a test bucket and upload files
  mc mb minio/test-bucket
  for i in $(seq 1 100); do
    echo "test data $i" | mc pipe minio/test-bucket/file-$i.txt
  done

  # List objects, get objects, etc.
  mc ls minio/test-bucket
  mc cat minio/test-bucket/file-1.txt
  mc stat minio/test-bucket/file-1.txt

STEP 2: Wait for Logs to be Committed
=====================================
The API logs are:
  1. Written to local storage on each MinIO node
  2. Periodically batched into Parquet files (write_interval)
  3. Committed to the Iceberg table by the leader (commit_interval)

Default intervals are 30s write / 1m commit for this test setup.
Wait at least 2 minutes after generating traffic for logs to appear.

STEP 3: Query Logs with Trino
=============================
Connect to Trino and query the API logs:

  # Using Trino CLI
  docker exec -it trino trino

  # In Trino, query the table
  USE {catalog_name}.{NAMESPACE};
  SELECT COUNT(*) FROM {TABLE_NAME};
  SELECT time, name, bucket, object, httpStatusCode FROM {TABLE_NAME} LIMIT 10;
  SELECT name, COUNT(*) as cnt FROM {TABLE_NAME} GROUP BY name ORDER BY cnt DESC;

  # Time-based queries
  SELECT * FROM {TABLE_NAME} WHERE time > TIMESTAMP '2024-01-01 00:00:00';

ALTERNATIVE: Create Trino Catalog Manually
==========================================
If the catalog wasn't created automatically, create it in Trino:

  CREATE CATALOG {catalog_name} USING iceberg WITH (
    "iceberg.catalog.type" = 'rest',
    "iceberg.rest-catalog.uri" = '{MINIO_ENDPOINT}/_iceberg',
    "iceberg.rest-catalog.warehouse" = '{WAREHOUSE_BUCKET}',
    "iceberg.rest-catalog.vended-credentials-enabled" = 'true',
    "iceberg.rest-catalog.security" = 'SIGV4',
    "iceberg.rest-catalog.signing-name" = 's3tables',
    "s3.region" = 'us-east-1',
    "s3.aws-access-key" = '{ACCESS_KEY}',
    "s3.aws-secret-key" = '{SECRET_KEY}',
    "s3.endpoint" = '{MINIO_ENDPOINT}',
    "s3.path-style-access" = 'true',
    "fs.hadoop.enabled" = 'false',
    "fs.native-s3.enabled" = 'true'
  );

WEB INTERFACES:
  - MinIO Console: http://localhost:9001 ({ACCESS_KEY}/{SECRET_KEY})
  - Trino UI: http://localhost:9999
""")
    print("=" * 70)


def main():
    log("=" * 60)
    log("API Log Iceberg Integration Test - Initialization")
    log("=" * 60)

    # Wait for MinIO
    wait_for_minio()

    # Setup Trino catalog
    catalog_name = setup_trino_catalog()

    # Print instructions
    print_instructions(catalog_name)

    log("=" * 60)
    log("Initialization complete!")
    log("=" * 60)

    return 0


if __name__ == "__main__":
    sys.exit(main())
