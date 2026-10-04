aws lambda publish-layer-version \
  --layer-name pyarrow-311 \
  --compatible-runtimes python3.11 \
  --compatible-architectures x86_64 \
  --zip-file fileb://dist/pyarrow-layer.zip