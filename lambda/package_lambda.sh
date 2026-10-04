#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
PACKAGE_PATH="${DIST_DIR}/function.zip"

mkdir -p "${DIST_DIR}"
rm -f "${PACKAGE_PATH}"

(
  python3 - "${SCRIPT_DIR}" "${PACKAGE_PATH}" <<'PY'
import pathlib
import sys
import zipfile

source_dir = pathlib.Path(sys.argv[1])
package_path = pathlib.Path(sys.argv[2])
source_file = source_dir / "app.py"
# Bundle the canonical city config next to the handler so the Lambda can load
# it at runtime from a single source of truth.
cities_file = source_dir.parent / "data" / "cities.json"

with zipfile.ZipFile(package_path, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
    bundle.write(source_file, arcname="app.py")
    bundle.write(cities_file, arcname="cities.json")
PY
)

echo "Created ${PACKAGE_PATH}"
