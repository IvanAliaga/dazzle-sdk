#!/usr/bin/env python3
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""
Generate a deterministic synthetic sensor dataset for the Valkey context injection experiment.

Produces research/data/dataset_iot_baseline.json with:
  - 200 temperature/humidity readings (some with injected anomalies)
  - 30 structured questions with ground-truth answers in three categories:
      current   (10) – only the current reading needed
      recent    (10) – last 5–10 readings needed
      longterm  (10) – full history / aggregates needed

Usage:
    python research/scripts/generate_dataset.py
"""

import json
import math
import random
import os

SEED = 42
NUM_READINGS = 200
# Output path resolves to research/data/dataset_iot_baseline.json (sibling of scripts/)
OUTPUT_PATH = os.path.join(os.path.dirname(__file__), "..", "data", "dataset_iot_baseline.json")

# Anomaly definitions: (start_index, duration, type, description)
ANOMALIES = [
    (45,  1,  "spike",    "sudden spike to 32°C"),
    (89,  8,  "drift",    "gradual upward drift from 24 to 31°C"),
    (110, 3,  "dropout",  "sensor dropout: values near 0°C"),
    (140, 6,  "oscillation", "rapid oscillation between 20 and 29°C"),
    (175, 1,  "spike",    "sudden spike to 34°C"),
]

NORMAL_MEAN = 22.5
NORMAL_STD  = 0.8
HUMIDITY_MEAN = 45.0
HUMIDITY_STD  = 3.0

ANOMALY_THRESHOLD = 28.0   # °C – readings above this are flagged as anomalous
DROPOUT_THRESHOLD = 5.0    # °C – readings below this are flagged as dropouts


def is_anomalous(temp: float) -> bool:
    return temp > ANOMALY_THRESHOLD or temp < DROPOUT_THRESHOLD


def generate_readings() -> list[dict]:
    rng = random.Random(SEED)
    readings = []

    # Build a set of anomalous minute indices for fast lookup
    anomaly_minutes: set[int] = set()
    for start, dur, _, _ in ANOMALIES:
        for i in range(start, start + dur):
            anomaly_minutes.add(i)

    for i in range(NUM_READINGS):
        # Base normal reading
        temp     = rng.gauss(NORMAL_MEAN, NORMAL_STD)
        humidity = rng.gauss(HUMIDITY_MEAN, HUMIDITY_STD)

        # Apply anomaly modifications
        for start, dur, atype, _ in ANOMALIES:
            if start <= i < start + dur:
                if atype == "spike":
                    temp = rng.uniform(31.0, 35.0)
                elif atype == "drift":
                    progress = (i - start) / max(dur - 1, 1)
                    temp = NORMAL_MEAN + progress * 8.5 + rng.gauss(0, 0.3)
                elif atype == "dropout":
                    temp = rng.uniform(0.5, 3.0)
                    humidity = rng.uniform(0, 5)
                elif atype == "oscillation":
                    phase = (i - start) % 2
                    temp = (20.0 if phase == 0 else 29.0) + rng.gauss(0, 0.3)

        temp     = round(temp, 1)
        humidity = round(humidity, 1)

        readings.append({
            "minute":    i,
            "timestamp": f"2024-03-15T10:{i // 60:02d}:{i % 60:02d}",
            "temp_c":    temp,
            "humidity":  humidity,
            "anomalous": is_anomalous(temp),
        })

    return readings


def compute_stats(readings: list[dict]) -> dict:
    temps = [r["temp_c"] for r in readings]
    anomaly_indices = [r["minute"] for r in readings if r["anomalous"]]
    return {
        "count":         len(readings),
        "avg_temp":      round(sum(temps) / len(temps), 2),
        "min_temp":      min(temps),
        "max_temp":      max(temps),
        "anomaly_count": len(anomaly_indices),
        "anomaly_minutes": anomaly_indices,
    }


def compute_trend(window: list[dict]) -> str:
    """Classify trend of a readings window as increasing/decreasing/stable."""
    if len(window) < 2:
        return "stable"
    temps = [r["temp_c"] for r in window]
    # Simple linear regression slope
    n = len(temps)
    mean_x = (n - 1) / 2
    mean_y = sum(temps) / n
    num = sum((i - mean_x) * (temps[i] - mean_y) for i in range(n))
    den = sum((i - mean_x) ** 2 for i in range(n))
    slope = num / den if den != 0 else 0.0
    if slope > 0.15:
        return "increasing"
    if slope < -0.15:
        return "decreasing"
    return "stable"


def build_questions(readings: list[dict], stats: dict) -> list[dict]:
    questions = []

    # ── Category: current ───────────────────────────────────────────────────
    # Probe at reading index 150 (well into the dataset, past all anomalies)
    idx = 150
    r   = readings[idx]

    questions += [
        {
            "id": "cur_01",
            "category": "current",
            "probe_index": idx,
            "text": "What is the current temperature in Celsius? Reply as JSON: {\"answer\": <number>}",
            "ground_truth": r["temp_c"],
            "score_type": "number_tolerance",
            "tolerance": 1.0,
        },
        {
            "id": "cur_02",
            "category": "current",
            "probe_index": idx,
            "text": "Is the current temperature above 25°C? Reply as JSON: {\"answer\": \"yes\" or \"no\"}",
            "ground_truth": "yes" if r["temp_c"] > 25.0 else "no",
            "score_type": "exact",
        },
        {
            "id": "cur_03",
            "category": "current",
            "probe_index": idx,
            "text": "Is the current humidity above 50%? Reply as JSON: {\"answer\": \"yes\" or \"no\"}",
            "ground_truth": "yes" if r["humidity"] > 50.0 else "no",
            "score_type": "exact",
        },
        {
            "id": "cur_04",
            "category": "current",
            "probe_index": idx,
            "text": "Is the current temperature in the normal operating range (18–27°C)? Reply as JSON: {\"answer\": \"yes\" or \"no\"}",
            "ground_truth": "yes" if 18.0 <= r["temp_c"] <= 27.0 else "no",
            "score_type": "exact",
        },
        {
            "id": "cur_05",
            "category": "current",
            "probe_index": idx,
            "text": "Round the current temperature to the nearest integer. Reply as JSON: {\"answer\": <integer>}",
            "ground_truth": round(r["temp_c"]),
            "score_type": "exact",
        },
        {
            "id": "cur_06",
            "category": "current",
            "probe_index": idx,
            "text": "Is the current temperature above or below 20°C? Reply as JSON: {\"answer\": \"above\" or \"below\"}",
            "ground_truth": "above" if r["temp_c"] > 20.0 else "below",
            "score_type": "exact",
        },
        {
            "id": "cur_07",
            "category": "current",
            "probe_index": idx,
            "text": "What is the difference between current temperature and 22°C? Reply as JSON: {\"answer\": <number>} (positive = above 22, negative = below 22)",
            "ground_truth": round(r["temp_c"] - 22.0, 1),
            "score_type": "number_tolerance",
            "tolerance": 1.0,
        },
        {
            "id": "cur_08",
            "category": "current",
            "probe_index": idx,
            "text": "Is this reading likely to be an anomaly? An anomaly is defined as temperature above 28°C or below 5°C. Reply as JSON: {\"answer\": \"yes\" or \"no\"}",
            "ground_truth": "yes" if r["anomalous"] else "no",
            "score_type": "exact",
        },
        {
            "id": "cur_09",
            "category": "current",
            "probe_index": idx,
            "text": "Is humidity within the acceptable range of 30–70%? Reply as JSON: {\"answer\": \"yes\" or \"no\"}",
            "ground_truth": "yes" if 30.0 <= r["humidity"] <= 70.0 else "no",
            "score_type": "exact",
        },
        {
            "id": "cur_10",
            "category": "current",
            "probe_index": idx,
            "text": "What category best describes the current temperature: cold (<18°C), normal (18–27°C), or hot (>27°C)? Reply as JSON: {\"answer\": \"cold\", \"normal\", or \"hot\"}",
            "ground_truth": "cold" if r["temp_c"] < 18 else ("hot" if r["temp_c"] > 27 else "normal"),
            "score_type": "exact",
        },
    ]

    # ── Category: recent ────────────────────────────────────────────────────
    # Probe at index 160; the window of the last 10 readings is [150..159]
    idx   = 160
    win10 = readings[150:160]
    win5  = readings[155:160]
    trend10 = compute_trend(win10)
    trend5  = compute_trend(win5)
    recent_anomaly_count = sum(1 for r2 in win10 if r2["anomalous"])
    recent_max = max(r2["temp_c"] for r2 in win10)
    recent_avg = round(sum(r2["temp_c"] for r2 in win10) / len(win10), 1)

    questions += [
        {
            "id": "rec_01",
            "category": "recent",
            "probe_index": idx,
            "text": "What is the temperature trend over the last 10 readings: increasing, decreasing, or stable? Reply as JSON: {\"answer\": \"increasing\", \"decreasing\", or \"stable\"}",
            "ground_truth": trend10,
            "score_type": "exact",
        },
        {
            "id": "rec_02",
            "category": "recent",
            "probe_index": idx,
            "text": "Has there been any anomaly (temperature above 28°C or below 5°C) in the last 10 readings? Reply as JSON: {\"answer\": \"yes\" or \"no\"}",
            "ground_truth": "yes" if recent_anomaly_count > 0 else "no",
            "score_type": "exact",
        },
        {
            "id": "rec_03",
            "category": "recent",
            "probe_index": idx,
            "text": "How many anomalies occurred in the last 10 readings? Reply as JSON: {\"answer\": <integer>}",
            "ground_truth": recent_anomaly_count,
            "score_type": "number_tolerance",
            "tolerance": 0,
        },
        {
            "id": "rec_04",
            "category": "recent",
            "probe_index": idx,
            "text": "What was the maximum temperature in the last 10 readings? Reply as JSON: {\"answer\": <number>}",
            "ground_truth": recent_max,
            "score_type": "number_tolerance",
            "tolerance": 1.0,
        },
        {
            "id": "rec_05",
            "category": "recent",
            "probe_index": idx,
            "text": "What is the average temperature over the last 10 readings? Reply as JSON: {\"answer\": <number>}",
            "ground_truth": recent_avg,
            "score_type": "number_tolerance",
            "tolerance": 1.0,
        },
        {
            "id": "rec_06",
            "category": "recent",
            "probe_index": idx,
            "text": "Is the temperature trend over the last 5 readings increasing, decreasing, or stable? Reply as JSON: {\"answer\": \"increasing\", \"decreasing\", or \"stable\"}",
            "ground_truth": trend5,
            "score_type": "exact",
        },
        {
            "id": "rec_07",
            "category": "recent",
            "probe_index": idx,
            "text": "Were all of the last 10 readings within the normal range (18–27°C)? Reply as JSON: {\"answer\": \"yes\" or \"no\"}",
            "ground_truth": "yes" if all(18 <= r2["temp_c"] <= 27 for r2 in win10) else "no",
            "score_type": "exact",
        },
        {
            "id": "rec_08",
            "category": "recent",
            "probe_index": idx,
            "text": "Was the previous reading (one minute ago) higher or lower than the current reading? Reply as JSON: {\"answer\": \"higher\" or \"lower\"}",
            "ground_truth": "higher" if readings[idx - 1]["temp_c"] > readings[idx]["temp_c"] else "lower",
            "score_type": "exact",
        },
        {
            "id": "rec_09",
            "category": "recent",
            "probe_index": idx,
            "text": "Is the current temperature above the average of the last 10 readings? Reply as JSON: {\"answer\": \"yes\" or \"no\"}",
            "ground_truth": "yes" if readings[idx]["temp_c"] > recent_avg else "no",
            "score_type": "exact",
        },
        {
            "id": "rec_10",
            "category": "recent",
            "probe_index": idx,
            "text": "How many of the last 10 readings were above 23°C? Reply as JSON: {\"answer\": <integer>}",
            "ground_truth": sum(1 for r2 in win10 if r2["temp_c"] > 23.0),
            "score_type": "number_tolerance",
            "tolerance": 0,
        },
    ]

    # ── Category: longterm ──────────────────────────────────────────────────
    # Probe at the very last reading; full history is available in Valkey
    idx = NUM_READINGS - 1

    # Last anomaly minute
    last_anomaly_minute = max(stats["anomaly_minutes"]) if stats["anomaly_minutes"] else -1

    # Number of readings above 28°C
    above28 = sum(1 for r2 in readings if r2["temp_c"] > 28.0)

    # Minute with peak temp
    peak_reading = max(readings, key=lambda r2: r2["temp_c"])

    questions += [
        {
            "id": "lng_01",
            "category": "longterm",
            "probe_index": idx,
            "text": "How many total anomalies (temperature above 28°C or below 5°C) have been detected across all readings? Reply as JSON: {\"answer\": <integer>}",
            "ground_truth": stats["anomaly_count"],
            "score_type": "number_tolerance",
            "tolerance": 2,
        },
        {
            "id": "lng_02",
            "category": "longterm",
            "probe_index": idx,
            "text": "What is the overall average temperature across all readings? Reply as JSON: {\"answer\": <number>}",
            "ground_truth": stats["avg_temp"],
            "score_type": "number_tolerance",
            "tolerance": 1.0,
        },
        {
            "id": "lng_03",
            "category": "longterm",
            "probe_index": idx,
            "text": "What is the highest temperature ever recorded? Reply as JSON: {\"answer\": <number>}",
            "ground_truth": stats["max_temp"],
            "score_type": "number_tolerance",
            "tolerance": 1.0,
        },
        {
            "id": "lng_04",
            "category": "longterm",
            "probe_index": idx,
            "text": "What is the lowest temperature ever recorded? Reply as JSON: {\"answer\": <number>}",
            "ground_truth": stats["min_temp"],
            "score_type": "number_tolerance",
            "tolerance": 1.0,
        },
        {
            "id": "lng_05",
            "category": "longterm",
            "probe_index": idx,
            "text": f"Has there been an anomaly in the last 20 readings (minutes {idx - 19} to {idx})? Reply as JSON: {{\"answer\": \"yes\" or \"no\"}}",
            "ground_truth": "yes" if any(r2["anomalous"] for r2 in readings[idx - 19:idx + 1]) else "no",
            "score_type": "exact",
        },
        {
            "id": "lng_06",
            "category": "longterm",
            "probe_index": idx,
            "text": "How many readings were above 28°C in total? Reply as JSON: {\"answer\": <integer>}",
            "ground_truth": above28,
            "score_type": "number_tolerance",
            "tolerance": 3,
        },
        {
            "id": "lng_07",
            "category": "longterm",
            "probe_index": idx,
            "text": "Is the overall average temperature above 23°C? Reply as JSON: {\"answer\": \"yes\" or \"no\"}",
            "ground_truth": "yes" if stats["avg_temp"] > 23.0 else "no",
            "score_type": "exact",
        },
        {
            "id": "lng_08",
            "category": "longterm",
            "probe_index": idx,
            "text": "Have there been more than 5 anomalous readings overall? Reply as JSON: {\"answer\": \"yes\" or \"no\"}",
            "ground_truth": "yes" if stats["anomaly_count"] > 5 else "no",
            "score_type": "exact",
        },
        {
            "id": "lng_09",
            "category": "longterm",
            "probe_index": idx,
            "text": "What is the temperature range (max minus min) across all readings? Reply as JSON: {\"answer\": <number>}",
            "ground_truth": round(stats["max_temp"] - stats["min_temp"], 1),
            "score_type": "number_tolerance",
            "tolerance": 1.5,
        },
        {
            "id": "lng_10",
            "category": "longterm",
            "probe_index": idx,
            "text": "Has the sensor ever recorded a dropout (temperature below 5°C)? Reply as JSON: {\"answer\": \"yes\" or \"no\"}",
            "ground_truth": "yes" if any(r2["temp_c"] < 5.0 for r2 in readings) else "no",
            "score_type": "exact",
        },
    ]

    return questions


def main():
    readings  = generate_readings()
    stats     = compute_stats(readings)
    questions = build_questions(readings, stats)

    dataset = {
        "meta": {
            "seed":          SEED,
            "num_readings":  NUM_READINGS,
            "anomaly_threshold_high": ANOMALY_THRESHOLD,
            "anomaly_threshold_low":  DROPOUT_THRESHOLD,
            "normal_range":  [18.0, 27.0],
            "injected_anomalies": [
                {"start": s, "duration": d, "type": t, "description": desc}
                for s, d, t, desc in ANOMALIES
            ],
        },
        "stats":     stats,
        "readings":  readings,
        "questions": questions,
    }

    os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)
    with open(OUTPUT_PATH, "w") as f:
        json.dump(dataset, f, indent=2)

    print(f"Dataset written to {OUTPUT_PATH}")
    print(f"  Readings:  {len(readings)}")
    print(f"  Questions: {len(questions)} ({sum(1 for q in questions if q['category']=='current')} current, "
          f"{sum(1 for q in questions if q['category']=='recent')} recent, "
          f"{sum(1 for q in questions if q['category']=='longterm')} longterm)")
    print(f"  Anomalous readings: {stats['anomaly_count']}")
    print(f"  Temp range: {stats['min_temp']}–{stats['max_temp']}°C  avg={stats['avg_temp']}°C")


if __name__ == "__main__":
    main()
