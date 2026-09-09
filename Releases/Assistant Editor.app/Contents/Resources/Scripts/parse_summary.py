#!/usr/bin/env python3
"""Parse summary.yaml → JSON markers array."""
import sys, json, yaml

def parse_summary(path):
    with open(path, encoding="utf-8") as f:
        data = yaml.safe_load(f)
    markers = data.get("markers", []) if isinstance(data, dict) else []
    return {"markers": markers}

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: parse_summary.py <summary.yaml>"}))
        sys.exit(1)
    result = parse_summary(sys.argv[1])
    print(json.dumps(result, ensure_ascii=False))
