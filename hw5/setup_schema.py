#!/usr/bin/env python3
"""
setup_schema.py - Creates Cloud SQL (MySQL) tables for HW5.
Run once after the Cloud SQL instance is created/started.

Usage:
    DB_HOST=127.0.0.1 DB_PORT=3306 DB_NAME=hw5db \
    DB_USER=hw5user DB_PASSWORD=<pw> python3 setup_schema.py

Or with Unix socket (via Cloud SQL Proxy):
    DB_SOCKET=/cloudsql/<PROJECT>:<REGION>:<INSTANCE> \
    DB_NAME=hw5db DB_USER=hw5user DB_PASSWORD=<pw> python3 setup_schema.py
"""

import os
import sys

import pymysql
import pymysql.cursors

DB_HOST     = os.environ.get("DB_HOST", "127.0.0.1")
DB_PORT     = int(os.environ.get("DB_PORT", "3306"))
DB_NAME     = os.environ.get("DB_NAME", "hw5db")
DB_USER     = os.environ.get("DB_USER", "hw5user")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "")
DB_SOCKET   = os.environ.get("DB_SOCKET", "")


def get_connection(database=None):
    kwargs = dict(
        host=DB_HOST,
        port=DB_PORT,
        user=DB_USER,
        password=DB_PASSWORD,
        charset="utf8mb4",
        cursorclass=pymysql.cursors.DictCursor,
        autocommit=True,
    )
    if database:
        kwargs["database"] = database
    if DB_SOCKET:
        kwargs["unix_socket"] = DB_SOCKET
        del kwargs["host"]
        del kwargs["port"]
    return pymysql.connect(**kwargs)


def main():
    print(f"[schema] Connecting to MySQL at {DB_HOST}:{DB_PORT} ...")

    # 1. Ensure database exists
    conn = get_connection()
    with conn.cursor() as cur:
        cur.execute(f"CREATE DATABASE IF NOT EXISTS `{DB_NAME}` "
                    f"CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;")
    conn.close()
    print(f"[schema] Database '{DB_NAME}' ready.")

    # 2. Connect to the target database and create tables
    conn = get_connection(database=DB_NAME)
    with conn.cursor() as cur:

        # ── Main requests table ───────────────────────────────────────────────
        cur.execute("""
            CREATE TABLE IF NOT EXISTS requests (
                id             BIGINT        NOT NULL AUTO_INCREMENT,
                created_at     DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
                country        VARCHAR(100)  NOT NULL DEFAULT '',
                client_ip      VARCHAR(45)   NOT NULL DEFAULT '',
                gender         VARCHAR(20)   NOT NULL DEFAULT '',
                age            VARCHAR(50)   NOT NULL DEFAULT '',
                income         VARCHAR(50)   NOT NULL DEFAULT '',
                is_banned      TINYINT(1)    NOT NULL DEFAULT 0,
                time_of_day    VARCHAR(20)   NOT NULL DEFAULT '',
                requested_file VARCHAR(512)  NOT NULL DEFAULT '',
                PRIMARY KEY (id)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        """)
        print("[schema] Table 'requests' created (or already exists).")

        # ── Error / failed-requests table ─────────────────────────────────────
        cur.execute("""
            CREATE TABLE IF NOT EXISTS errors (
                id             BIGINT        NOT NULL AUTO_INCREMENT,
                created_at     DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
                requested_file VARCHAR(512)  NOT NULL DEFAULT '',
                error_code     SMALLINT      NOT NULL,
                PRIMARY KEY (id)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
        """)
        print("[schema] Table 'errors' created (or already exists).")

    conn.close()
    print("[schema] Schema setup complete.")


if __name__ == "__main__":
    main()
