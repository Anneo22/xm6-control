#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash -n Scripts/build_app.sh
python3 - <<'PYTHON'
import ast
from pathlib import Path
for path in [Path("Scripts/xm6control"), *Path("Scripts").glob("*.py")]:
    ast.parse(path.read_text(), filename=str(path))
print("Python syntax passed")
PYTHON
swift build
