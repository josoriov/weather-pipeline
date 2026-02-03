#!/bin/bash
# 0) Remove old layer if exists
sudo rm -rf ./dist/pyarrow-layer.zip

# 1) Build site-packages into ./python using the Lambda 3.13 image
docker run --rm --entrypoint /bin/bash -v "$PWD":/var/task public.ecr.aws/lambda/python:3.13 \
  -lc "python -m pip install --upgrade pip && python -m pip install --no-deps --no-cache-dir -r requirements.txt -t python"

# 2) Prune locally (host), then zip at max compression
#    – remove caches, tests, metadata; exclude pyc/pyo from the ZIP
find python -type d -name "__pycache__" -prune -exec rm -rf {} +
find python -type d \( -name "tests" -o -name "test" \) -prune -exec rm -rf {} +
find python -type d \( -name "*.dist-info" -o -name "*.egg-info" \) -prune -exec rm -rf {} +
find python -type f \( -name "*.pyc" -o -name "*.pyo" \) -delete

mkdir -p dist
sudo zip -r9 ./dist/pyarrow-layer.zip python \
  -x "*/__pycache__/*" -x "*/tests/*" -x "*/test/*" -x "*/*.dist-info/*" -x "*/*.egg-info/*" -x "*.pyc" -x "*.pyo"

# 3) Clean up
sudo rm -rf ./python
