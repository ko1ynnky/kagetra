#!/usr/bin/env bash

set -u

if [ "$#" -ne 2 ]; then
  echo "usage: $0 WIKI_ID ZIP_FILE" >&2
  exit 64
fi

if [ "$1" != "66" ]; then
  exit 0
fi

readonly archive="$2"
readonly publish_root="${KAGETRA_UT_KARUTA_PUBLISH_ROOT:-/var/www/html/ut-karuta}"
readonly release_dir="${publish_root}/upload-$(date +%s)-$$"
readonly pending_link="${publish_root}/.root-$$"

if [[ "$publish_root" != /* ]] || [ ! -d "$publish_root" ] || [ ! -f "$archive" ]; then
  echo "invalid publish root or archive" >&2
  exit 1
fi

case "$release_dir" in
  "$publish_root"/upload-*) ;;
  *)
    echo "unsafe release path" >&2
    exit 1
    ;;
esac

cleanup_on_error() {
  local status=$?
  if [ "$status" -ne 0 ]; then
    rm -f -- "$pending_link"
    case "$release_dir" in
      "$publish_root"/upload-*) rm -rf -- "$release_dir" ;;
    esac
  fi
}
trap cleanup_on_error EXIT

umask 022
mkdir -m 0755 -- "$release_dir" || exit 1

# Reject archive paths that could escape the new release directory.
while IFS= read -r entry; do
  case "$entry" in
    /*|../*|*/../*|*/..|*\\*)
      echo "unsafe archive path: $entry" >&2
      exit 1
      ;;
  esac
done < <(unzip -Z1 "$archive")

# Reject symlinks before extraction so later entries cannot traverse them.
if zipinfo -l "$archive" | awk '$1 ~ /^l/ { found=1 } END { exit(found ? 0 : 1) }'; then
  echo "archive contains a symbolic link" >&2
  exit 1
fi

readonly -a excluded_paths=(
  '.git' '.git/*' '*/.git' '*/.git/*'
  '.github' '.github/*' '*/.github' '*/.github/*'
  '.svn' '.svn/*' '*/.svn' '*/.svn/*'
  '.hg' '.hg/*' '*/.hg' '*/.hg/*'
  '.claude' '.claude/*' '*/.claude' '*/.claude/*'
  '.vscode' '.vscode/*' '*/.vscode' '*/.vscode/*'
  '.idea' '.idea/*' '*/.idea' '*/.idea/*'
  '.playwright-mcp' '.playwright-mcp/*' '*/.playwright-mcp' '*/.playwright-mcp/*'
  '.gitignore' '*/.gitignore'
  '.gitattributes' '*/.gitattributes'
  '.gitmodules' '*/.gitmodules'
  '.editorconfig' '*/.editorconfig'
  '.prettierrc' '*/.prettierrc'
  '.env' '.env.*' '*/.env' '*/.env.*'
  '.DS_Store' '*/.DS_Store'
  '__MACOSX' '__MACOSX/*' '*/__MACOSX' '*/__MACOSX/*'
  'CLAUDE.md' '*/CLAUDE.md'
  'AGENTS.md' '*/AGENTS.md'
  'README.md' '*/README.md'
  'package.json' '*/package.json'
  'package-lock.json' '*/package-lock.json'
)

unzip -q "$archive" -x "${excluded_paths[@]}" -d "$release_dir" \
  2> >(grep -Fv 'caution: excluded filename not matched:' >&2) || exit 1

shopt -s dotglob nullglob
entries=("$release_dir"/*)
site_dir="$release_dir"
if [ "${#entries[@]}" -eq 1 ] && [ -d "${entries[0]}" ]; then
  site_dir="${entries[0]}"
fi

if [ ! -f "$site_dir/index.html" ]; then
  echo "index.html was not found" >&2
  exit 1
fi

if find "$site_dir" -type l -print -quit | grep -q .; then
  echo "extracted site contains a symbolic link" >&2
  exit 1
fi

find "$site_dir" -type d -exec chmod 0755 {} + || exit 3
find "$site_dir" -type f -exec chmod 0644 {} + || exit 3

ln -s -- "$site_dir" "$pending_link" || exit 2
mv -Tf -- "$pending_link" "$publish_root/root" || exit 2

trap - EXIT
