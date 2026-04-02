#!/usr/bin/env python3
"""
models.py - HW6 Machine Learning Models

Model 1: Predict country from client_ip  (target: 99%+ accuracy)
    - Uses DecisionTreeClassifier on IP octets as features.
    - Since each IP maps to exactly one country, this is essentially
      a lookup — a decision tree learns this perfectly.

Model 2: Predict income from available fields  (target: 40%+ accuracy)
    - Uses RandomForestClassifier with gender, age, is_banned,
      time_of_day as features (label-encoded).

Outputs:
    - model1_results.txt  (IP -> Country test set predictions + accuracy)
    - model2_results.txt  (fields -> Income test set predictions + accuracy)
    - Both files are uploaded to GCS bucket.

Usage:
    DB_HOST=127.0.0.1 DB_PORT=3306 DB_NAME=hw5db \
    DB_USER=hw5user DB_PASSWORD=aumcloudhw123 \
    BUCKET_NAME=aum-hw2-u07079548 \
    python3 models.py
"""

import os
import sys
import time

import pymysql
import pymysql.cursors
import numpy as np
from sklearn.model_selection import train_test_split
from sklearn.tree import DecisionTreeClassifier
from sklearn.ensemble import RandomForestClassifier
from sklearn.preprocessing import LabelEncoder
from sklearn.metrics import accuracy_score, classification_report
from google.cloud import storage

# ── Configuration ────────────────────────────────────────────────────────────
DB_HOST     = os.environ.get("DB_HOST", "127.0.0.1")
DB_PORT     = int(os.environ.get("DB_PORT", "3306"))
DB_NAME     = os.environ.get("DB_NAME", "hw5db")
DB_USER     = os.environ.get("DB_USER", "hw5user")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "aumcloudhw123")
BUCKET_NAME = os.environ.get("BUCKET_NAME", "aum-hw2-u07079548")
PROJECT_ID  = os.environ.get("PROJECT_ID", "u0709548-aum-hw1")

OUTPUT_DIR = "/tmp/hw6_output"


def get_conn():
    return pymysql.connect(
        host=DB_HOST, port=DB_PORT,
        user=DB_USER, password=DB_PASSWORD,
        database=DB_NAME, charset="utf8mb4",
        cursorclass=pymysql.cursors.DictCursor,
        autocommit=True,
    )


def ip_to_features(ip_str):
    """Convert IP string '1.2.3.4' to 4 integer octets."""
    parts = ip_str.split(".")
    if len(parts) == 4:
        return [int(p) for p in parts]
    return [0, 0, 0, 0]


def fetch_data(conn):
    """Fetch request data, joining ip_country if 3NF migration was applied."""
    with conn.cursor() as cur:
        # Check if country column still exists in requests
        cur.execute("SHOW COLUMNS FROM requests LIKE 'country'")
        has_country = cur.fetchone() is not None

        if has_country:
            # Pre-migration schema
            cur.execute("""
                SELECT client_ip, country, gender, age, income,
                       is_banned, time_of_day
                FROM requests
                WHERE client_ip != '' AND country != ''
            """)
        else:
            # Post-3NF schema — join ip_country
            cur.execute("""
                SELECT r.client_ip, ic.country, r.gender, r.age, r.income,
                       r.is_banned, r.time_of_day
                FROM requests r
                JOIN ip_country ic ON r.client_ip = ic.client_ip
                WHERE r.client_ip != '' AND ic.country != ''
            """)
        return cur.fetchall()


def model1_ip_to_country(data):
    """
    Model 1: Predict country from client IP address.
    Uses DecisionTreeClassifier on IP octets.
    Expected accuracy: 99%+ (each IP maps to exactly one country).
    """
    print("=" * 60)
    print("MODEL 1: Predict Country from Client IP")
    print("=" * 60)

    # Prepare features (IP octets) and labels (country)
    X = np.array([ip_to_features(row["client_ip"]) for row in data])
    y = np.array([row["country"] for row in data])

    print(f"  Total samples  : {len(X)}")
    print(f"  Unique IPs     : {len(set(row['client_ip'] for row in data))}")
    print(f"  Unique countries: {len(set(y))}")

    # Train/test split (80/20)
    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.2, random_state=42
    )
    print(f"  Train size     : {len(X_train)}")
    print(f"  Test size      : {len(X_test)}")

    # Train Decision Tree
    t0 = time.time()
    clf = DecisionTreeClassifier(random_state=42)
    clf.fit(X_train, y_train)
    train_time = time.time() - t0
    print(f"  Training time  : {train_time:.2f}s")

    # Predict on test set
    y_pred = clf.predict(X_test)
    accuracy = accuracy_score(y_test, y_pred)
    print(f"  Test accuracy  : {accuracy * 100:.2f}%")
    print()

    # Build output file
    lines = []
    lines.append("MODEL 1: Predict Country from Client IP")
    lines.append(f"Algorithm: DecisionTreeClassifier")
    lines.append(f"Features: IP address octets (4 integers)")
    lines.append(f"Total samples: {len(X)}, Train: {len(X_train)}, Test: {len(X_test)}")
    lines.append(f"Test Accuracy: {accuracy * 100:.2f}%")
    lines.append(f"Training Time: {train_time:.2f}s")
    lines.append("")
    lines.append("Classification Report:")
    lines.append(classification_report(y_test, y_pred, zero_division=0))
    lines.append("")
    lines.append("Test Set Predictions (first 100 rows):")
    lines.append(f"{'IP Octets':<20} {'Actual':<30} {'Predicted':<30} {'Correct'}")
    lines.append("-" * 100)
    for i in range(min(100, len(X_test))):
        ip_str = ".".join(str(o) for o in X_test[i])
        correct = "YES" if y_test[i] == y_pred[i] else "NO"
        lines.append(f"{ip_str:<20} {y_test[i]:<30} {y_pred[i]:<30} {correct}")

    output = "\n".join(lines)
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    fpath = os.path.join(OUTPUT_DIR, "model1_results.txt")
    with open(fpath, "w") as f:
        f.write(output)
    print(f"  Results written to {fpath}")

    return fpath, accuracy


def model2_predict_income(data):
    """
    Model 2: Predict income from available fields.
    Uses RandomForestClassifier with gender, age, is_banned, time_of_day.
    Target accuracy: 40%+.
    """
    print("=" * 60)
    print("MODEL 2: Predict Income from Request Fields")
    print("=" * 60)

    # Filter rows with non-empty income
    filtered = [r for r in data if r["income"] and r["income"].strip()]
    print(f"  Samples with income: {len(filtered)}")

    if not filtered:
        print("  ERROR: No rows with income data found!")
        return None, 0.0

    # Encode categorical features
    le_gender = LabelEncoder()
    le_age = LabelEncoder()
    le_tod = LabelEncoder()
    le_country = LabelEncoder()
    le_income = LabelEncoder()

    genders   = [r["gender"] for r in filtered]
    ages      = [r["age"] for r in filtered]
    times     = [r["time_of_day"] for r in filtered]
    countries = [r["country"] for r in filtered]
    banned    = [int(r["is_banned"]) for r in filtered]
    incomes   = [r["income"] for r in filtered]

    le_gender.fit(genders)
    le_age.fit(ages)
    le_tod.fit(times)
    le_country.fit(countries)
    le_income.fit(incomes)

    X = np.column_stack([
        le_gender.transform(genders),
        le_age.transform(ages),
        le_tod.transform(times),
        le_country.transform(countries),
        np.array(banned),
    ])
    y = le_income.transform(incomes)

    print(f"  Features       : gender, age, time_of_day, country, is_banned")
    print(f"  Target         : income")
    print(f"  Unique incomes : {len(le_income.classes_)}")
    print(f"  Income classes : {list(le_income.classes_)}")

    # Train/test split
    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.2, random_state=42
    )
    print(f"  Train size     : {len(X_train)}")
    print(f"  Test size      : {len(X_test)}")

    # Train Random Forest
    t0 = time.time()
    clf = RandomForestClassifier(
        n_estimators=100,
        max_depth=20,
        random_state=42,
        n_jobs=-1,
    )
    clf.fit(X_train, y_train)
    train_time = time.time() - t0
    print(f"  Training time  : {train_time:.2f}s")

    # Predict
    y_pred = clf.predict(X_test)
    accuracy = accuracy_score(y_test, y_pred)
    print(f"  Test accuracy  : {accuracy * 100:.2f}%")
    print()

    # Decode predictions back to labels
    y_test_labels = le_income.inverse_transform(y_test)
    y_pred_labels = le_income.inverse_transform(y_pred)

    # Feature importance
    feature_names = ["gender", "age", "time_of_day", "country", "is_banned"]
    importances = clf.feature_importances_

    # Build output
    lines = []
    lines.append("MODEL 2: Predict Income from Request Fields")
    lines.append(f"Algorithm: RandomForestClassifier (100 trees, max_depth=20)")
    lines.append(f"Features: gender, age, time_of_day, country, is_banned")
    lines.append(f"Total samples: {len(X)}, Train: {len(X_train)}, Test: {len(X_test)}")
    lines.append(f"Test Accuracy: {accuracy * 100:.2f}%")
    lines.append(f"Training Time: {train_time:.2f}s")
    lines.append("")
    lines.append("Feature Importances:")
    for fname, imp in sorted(zip(feature_names, importances), key=lambda x: -x[1]):
        lines.append(f"  {fname:<15}: {imp:.4f}")
    lines.append("")
    lines.append("Classification Report:")
    lines.append(classification_report(
        y_test_labels, y_pred_labels, zero_division=0
    ))
    lines.append("")
    lines.append("Test Set Predictions (first 100 rows):")
    lines.append(f"{'Actual':<20} {'Predicted':<20} {'Correct'}")
    lines.append("-" * 60)
    for i in range(min(100, len(y_test_labels))):
        correct = "YES" if y_test_labels[i] == y_pred_labels[i] else "NO"
        lines.append(f"{y_test_labels[i]:<20} {y_pred_labels[i]:<20} {correct}")

    output = "\n".join(lines)
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    fpath = os.path.join(OUTPUT_DIR, "model2_results.txt")
    with open(fpath, "w") as f:
        f.write(output)
    print(f"  Results written to {fpath}")

    return fpath, accuracy


def upload_to_gcs(local_path, gcs_path):
    """Upload a local file to GCS."""
    client = storage.Client(project=PROJECT_ID)
    bucket = client.bucket(BUCKET_NAME)
    blob = bucket.blob(gcs_path)
    blob.upload_from_filename(local_path)
    print(f"  Uploaded: gs://{BUCKET_NAME}/{gcs_path}")


def main():
    print("HW6 - Machine Learning Models")
    print(f"  DB: {DB_HOST}:{DB_PORT}/{DB_NAME}")
    print(f"  Bucket: {BUCKET_NAME}")
    print()

    # Fetch data
    conn = get_conn()
    print("Fetching data from database ...")
    data = fetch_data(conn)
    conn.close()
    print(f"  Fetched {len(data)} rows.")
    print()

    if not data:
        print("ERROR: No data found in database!")
        sys.exit(1)

    # Model 1: IP -> Country
    m1_path, m1_acc = model1_ip_to_country(data)
    print()

    # Model 2: Fields -> Income
    m2_path, m2_acc = model2_predict_income(data)
    print()

    # Upload results to GCS
    print("=" * 60)
    print("UPLOADING RESULTS TO GCS")
    print("=" * 60)
    if m1_path:
        upload_to_gcs(m1_path, "hw6/model1_results.txt")
    if m2_path:
        upload_to_gcs(m2_path, "hw6/model2_results.txt")

    print()
    print("=" * 60)
    print("SUMMARY")
    print("=" * 60)
    print(f"  Model 1 (IP -> Country)   : {m1_acc * 100:.2f}% accuracy")
    print(f"  Model 2 (Fields -> Income) : {m2_acc * 100:.2f}% accuracy")
    print(f"  Results uploaded to: gs://{BUCKET_NAME}/hw6/")
    print("=" * 60)


if __name__ == "__main__":
    main()
