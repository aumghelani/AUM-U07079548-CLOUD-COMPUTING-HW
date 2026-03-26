#!/usr/bin/env python3
"""
query_stats.py - Compute HW5 statistics from Cloud SQL after 50,000 requests.

Usage (run from local machine after setup.sh, with Cloud SQL public IP authorized):
    DB_HOST=<sql-public-ip> DB_NAME=hw5db DB_USER=hw5user \
    DB_PASSWORD=aumcloudhw@123 python3 query_stats.py

Or on VM1 (via Cloud SQL Proxy on 127.0.0.1):
    DB_HOST=127.0.0.1 DB_NAME=hw5db DB_USER=hw5user \
    DB_PASSWORD=aumcloudhw@123 python3 query_stats.py
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


def run(conn, sql):
    with conn.cursor() as cur:
        cur.execute(sql)
        return cur.fetchall()


def main():
    conn = get_conn()
    print(f"Connected to {DB_HOST}:{DB_PORT}/{DB_NAME}\n")
    print("=" * 60)

    # 1. Successful vs unsuccessful requests
    rows = run(conn, """
        SELECT
            SUM(CASE WHEN is_banned = 0 THEN 1 ELSE 0 END) AS successful,
            SUM(CASE WHEN is_banned = 1 THEN 1 ELSE 0 END) AS unsuccessful
        FROM requests
    """)
    r = rows[0]
    print(f"1. Successful vs Unsuccessful requests:")
    print(f"   Successful   : {r['successful']}")
    print(f"   Unsuccessful : {r['unsuccessful']}")
    print()

    # 2. Requests from banned countries
    rows = run(conn, """
        SELECT COUNT(*) AS banned_count
        FROM requests
        WHERE is_banned = 1
    """)
    print(f"2. Requests from banned countries: {rows[0]['banned_count']}")
    print()

    # 3. Male vs Female requests
    rows = run(conn, """
        SELECT gender, COUNT(*) AS cnt
        FROM requests
        GROUP BY gender
        ORDER BY cnt DESC
    """)
    print(f"3. Requests by gender:")
    for r in rows:
        print(f"   {r['gender'] or '(unknown)':<12}: {r['cnt']}")
    print()

    # 4. Top 5 countries
    rows = run(conn, """
        SELECT country, COUNT(*) AS cnt
        FROM requests
        GROUP BY country
        ORDER BY cnt DESC
        LIMIT 5
    """)
    print(f"4. Top 5 countries sending requests:")
    for i, r in enumerate(rows, 1):
        print(f"   {i}. {r['country'] or '(unknown)':<30}: {r['cnt']}")
    print()

    # 5. Age group with most requests
    rows = run(conn, """
        SELECT age, COUNT(*) AS cnt
        FROM requests
        GROUP BY age
        ORDER BY cnt DESC
        LIMIT 1
    """)
    r = rows[0]
    print(f"5. Age group with most requests: {r['age'] or '(unknown)'} ({r['cnt']} requests)")
    print()

    # 6. Income group with most requests
    rows = run(conn, """
        SELECT income, COUNT(*) AS cnt
        FROM requests
        GROUP BY income
        ORDER BY cnt DESC
        LIMIT 1
    """)
    r = rows[0]
    print(f"6. Income group with most requests: {r['income'] or '(unknown)'} ({r['cnt']} requests)")
    print()

    print("=" * 60)
    conn.close()


if __name__ == "__main__":
    main()
