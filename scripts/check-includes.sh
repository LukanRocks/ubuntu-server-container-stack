#!/usr/bin/env bash
# Keeps the include: list in docker-compose.yaml honest:
#   - every compose/*/*.yaml file is referenced by the list
#   - every entry in the list points at a file that exists
# A commented-out entry counts as referenced (a service can be parked), but it
# is reported so it doesn't stay forgotten.
#
# Run after adding, renaming or deleting a service file.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck disable=SC1091
set -a; . ./.env; set +a

status=0
referenced=()
parked=()

while IFS= read -r line; do
  # "  - $IOT_DIR/esphome.yaml # comment"  ->  var=IOT_DIR file=esphome.yaml
  read -r var file <<<"$(sed -E 's/.*-[[:space:]]*\$([A-Z_]+)\/([^[:space:]]+\.yaml).*/\1 \2/' <<<"$line")"
  dir=${!var:-}
  if [[ -z $dir ]]; then
    echo "ERROR: include entry uses \$$var, which is not set in .env: $file"
    status=1
    continue
  fi

  path="$dir/$file"
  rel=${path#"$PWD"/}
  referenced+=("$rel")

  if [[ ! -f $path ]]; then
    echo "ERROR: include entry points at a missing file: $rel"
    status=1
  fi

  [[ $line =~ ^[[:space:]]*# ]] && parked+=("$rel")
done < <(grep -E '^[[:space:]]*#?[[:space:]]*-[[:space:]]*\$[A-Z_]+/.*\.yaml' docker-compose.yaml)

for path in compose/*/*.yaml; do
  found=no
  for rel in "${referenced[@]}"; do
    [[ $rel == "$path" ]] && found=yes && break
  done
  if [[ $found == no ]]; then
    if [[ ! -s $path ]]; then
      # An empty file can't be included anyway — a service being drafted.
      echo "note: $path is empty and not in the include: list yet"
    else
      echo "ERROR: $path is not in the include: list in docker-compose.yaml"
      status=1
    fi
  fi
done

for rel in "${parked[@]:-}"; do
  [[ -n $rel ]] && echo "note: $rel is commented out of the include: list"
done

if [[ $status -eq 0 ]]; then
  echo "ok: ${#referenced[@]} include entries match the files in compose/"
fi

exit $status
