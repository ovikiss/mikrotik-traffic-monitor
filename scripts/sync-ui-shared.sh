#!/usr/bin/env sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SHARED_TMP_DIR=""

cleanup() {
  if [ -n "$SHARED_TMP_DIR" ] && [ -d "$SHARED_TMP_DIR" ]; then
    rm -rf "$SHARED_TMP_DIR"
  fi
}

trap cleanup EXIT INT TERM

find_shared_dir() {
  if [ -n "${UI_SHARED_DIR:-}" ] && [ -d "${UI_SHARED_DIR}" ]; then
    printf '%s\n' "${UI_SHARED_DIR}"
    return 0
  fi

  if [ -n "${UI_SHARED_REPO:-}" ]; then
    SHARED_TMP_DIR="$(mktemp -d)"
    shared_ref="${UI_SHARED_REF:-main}"
    git clone --depth 1 --branch "$shared_ref" "$UI_SHARED_REPO" "$SHARED_TMP_DIR" >/dev/null 2>&1
    printf '%s\n' "$SHARED_TMP_DIR"
    return 0
  fi

  for candidate in \
    "${ROOT_DIR}/../mikrotik-ui-shared" \
    "${HOME}/Downloads/mikrotik-ui-shared" \
    "/Users/ovi/Downloads/mikrotik-ui-shared"
  do
    if [ -d "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

SHARED_DIR="$(find_shared_dir)" || {
  echo "mikrotik-ui-shared not found. Set UI_SHARED_DIR to the shared repo path." >&2
  exit 1
}

copy_tree_files() {
  src_dir="$1"
  dst_dir="$2"
  mkdir -p "$dst_dir"
  find "$src_dir" -type f | while IFS= read -r src; do
    rel="${src#"$src_dir"/}"
    dst="$dst_dir/$rel"
    mkdir -p "$(dirname "$dst")"
    cp -f "$src" "$dst"
  done
}

rm -rf "${ROOT_DIR}/app/common" "${ROOT_DIR}/app/images" "${ROOT_DIR}/app/www/common" "${ROOT_DIR}/app/www/images"
rm -f "${ROOT_DIR}/app/www"/styles-*.css

mkdir -p "${ROOT_DIR}/app/i18n"
mkdir -p "${ROOT_DIR}/app/www/common"
mkdir -p "${ROOT_DIR}/app/www/images"

copy_tree_files "${SHARED_DIR}/ui/i18n" "${ROOT_DIR}/app/i18n"
copy_tree_files "${SHARED_DIR}/ui/common" "${ROOT_DIR}/app/www/common"
copy_tree_files "${SHARED_DIR}/ui/images" "${ROOT_DIR}/app/www/images"
for src in "${SHARED_DIR}"/ui/css/style-*.css; do
  [ -e "$src" ] || continue
  base="$(basename "$src")"
  base="${base/style-/styles-}"
  cp -f "$src" "${ROOT_DIR}/app/www/$base"
done

echo "Synced UI assets from ${SHARED_DIR}"
