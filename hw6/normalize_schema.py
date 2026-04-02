#!/usr/bin/env python3
"""
normalize_schema.py - Convert HW5 schema to 3rd Normal Form (3NF).

The HW5 'requests' table has a transitive dependency:
    id -> client_ip -> country
(A given IP always maps to the same country, but a country has many IPs.)

This script:
  1. Creates an 'ip_country' lookup table from existing data.
  2. Drops the 'country' column from 'requests' (it can be JOINed via client_ip).
  3. Prints the migration queries for the report.

Usage:
    DB_HOST=127.0.0.1 DB_PORT=3306 DB_NAME=hw5db \
    DB_USER=hw5user DB_PASSWORD=aumcloudhw123 python3 normalize_schema.py
"""

import os
import pymysql
import pymysql.cursors

DB_HOST     = os.environ.get("DB_HOST", "127.0.0.1")
DB_PORT     = int(os.environ.get("DB_PORT", "3306"))
DB_NAME     = os.environ.get("DB_NAME", "hw5db")
DB_USER     = os.environ.get("DB_USER", "hw5user")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "aumcloudhw123")


def get_conn():
    return pymysql.connect(
        host=DB_HOST, port=DB_PORT,
        user=DB_USER, password=DB_PASSWORD,
        database=DB_NAME, charset="utf8mb4",
        cursorclass=pymysql.cursors.DictCursor,
        autocommit=True,
    )


MIGRATION_QUERIES = [
    # Step 1: Create ip_country lookup table from existing data
    """
    CREATE TABLE IF NOT EXISTS ip_country (
        client_ip   VARCHAR(45)   NOT NULL,
        country     VARCHAR(100)  NOT NULL DEFAULT '',
        PRIMARY KEY (client_ip)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    """,

    # Step 2: Populate ip_country from the requests table
    #         (INSERT IGNORE avoids duplicates if run multiple times)
    """
    INSERT IGNORE INTO ip_country (client_ip, country)
    SELECT DISTINCT client_ip, country
    FROM requests;
    """,

    # Step 3: Drop the country column from requests (now derived via JOIN)
    """
    ALTER TABLE requests DROP COLUMN country;
    """,
]


def main():
    conn = get_conn()

    print("=" * 60)
    print("3NF SCHEMA MIGRATION")
    print("=" * 60)
    print()
    print("Transitive dependency identified:")
    print("  id -> client_ip -> country")
    print("  (Each IP always maps to exactly one country)")
    print()
    print("Migration steps:")
    print("  1. Create ip_country(client_ip PK, country) lookup table")
    print("  2. Populate ip_country from existing requests data")
    print("  3. Drop 'country' column from requests table")
    print()

    with conn.cursor() as cur:
        # Check if migration already done
        cur.execute("SHOW COLUMNS FROM requests LIKE 'country'")
        has_country = cur.fetchone() is not None

        if not has_country:
            print("[normalize] Migration already applied (country column removed).")
            # Verify ip_country exists
            cur.execute("SHOW TABLES LIKE 'ip_country'")
            if cur.fetchone():
                cur.execute("SELECT COUNT(*) AS cnt FROM ip_country")
                cnt = cur.fetchone()["cnt"]
                print(f"[normalize] ip_country table exists with {cnt} rows.")
            conn.close()
            return

        # Run migration
        for i, sql in enumerate(MIGRATION_QUERIES, 1):
            print(f"[normalize] Running step {i}/3 ...")
            print(f"  SQL: {sql.strip()[:120]}...")
            cur.execute(sql)
            print(f"  Done. Rows affected: {cur.rowcount}")
            print()

    # Verify
    with conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) AS cnt FROM ip_country")
        ip_cnt = cur.fetchone()["cnt"]
        cur.execute("SELECT COUNT(*) AS cnt FROM requests")
        req_cnt = cur.fetchone()["cnt"]

    print("=" * 60)
    print("MIGRATION COMPLETE")
    print(f"  ip_country table : {ip_cnt} unique IP->country mappings")
    print(f"  requests table   : {req_cnt} rows (country column removed)")
    print()
    print("New schema (3NF):")
    print("  requests(id PK, created_at, client_ip, gender, age, income,")
    print("           is_banned, time_of_day, requested_file)")
    print("  ip_country(client_ip PK, country)")
    print("  errors(id PK, created_at, requested_file, error_code)")
    print()
    print("To get country for a request, JOIN:")
    print("  SELECT r.*, ic.country")
    print("  FROM requests r")
    print("  JOIN ip_country ic ON r.client_ip = ic.client_ip;")
    print("=" * 60)

    conn.close()


if __name__ == "__main__":
    main()
