#!/usr/bin/env bash
set -euo pipefail

# 0) Remove old layer if exists
rm -rf ./dist/pyarrow-layer.zip

# 1) Build site-packages into ./python using the Lambda 3.11 image
docker run --rm --entrypoint /bin/bash -v "$PWD":/var/task public.ecr.aws/lambda/python:3.11 \
  -c "pip install --upgrade pip && pip install --no-deps --no-cache-dir -r requirements.txt -t python"

# 2) Fix ownership of files created by the Docker container (root by default)
sudo chown -R "$(id -u):$(id -g)" python dist 2>/dev/null || true

# 3) Prune caches, tests, metadata; exclude pyc/pyo from the ZIP
find python -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find python -type d \( -name "tests" -o -name "test" \) -exec rm -rf {} + 2>/dev/null || true
find python -type d \( -name "*.dist-info" -o -name "*.egg-info" \) -exec rm -rf {} + 2>/dev/null || true
find python -type f \( -name "*.pyc" -o -name "*.pyo" \) -delete 2>/dev/null || true

mkdir -p dist
zip -r9 ./dist/pyarrow-layer.zip python \
  -x "*/__pycache__/*" -x "*/tests/*" -x "*/test/*" -x "*/*.dist-info/*" -x "*/*.egg-info/*" -x "*.pyc" -x "*.pyo"

# 4) Clean up
rm -rf ./python

echo "Created ./dist/pyarrow-layer.zip"
