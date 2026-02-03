aws lambda publish-layer-version \
  --layer-name pyarrow-313 \
  --compatible-runtimes python3.13 \
  --compatible-architectures x86_64 \
  --zip-file fileb://dist/pyarrow-layer.zip