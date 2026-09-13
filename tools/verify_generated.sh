#!/usr/bin/env bash
set -euo pipefail

# B3 keeps this entry point present even before the generators land. A missing generator
# is a hard failure; an empty generated tree is not silently treated as verified.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -d "$root/model/generators" ]]; then
  echo "generated-artifact check failed: model/generators is missing" >&2
  exit 1
fi

if [[ ! -f "$root/model/schema/robot_model.schema.json" ]]; then
  echo "generated-artifact check failed: robot_model.schema.json is missing" >&2
  exit 1
fi

if [[ ! -f "$root/model/robot_model.yaml" ]]; then
  echo "generated-artifact check failed: model/robot_model.yaml is missing" >&2
  exit 1
fi

echo "generated-artifact check blocked: generators and source model are not implemented yet"
exit 2
