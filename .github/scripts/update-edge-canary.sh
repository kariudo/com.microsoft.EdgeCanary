#!/usr/bin/env bash
set -euo pipefail

MANIFEST_FILE="com.microsoft.Edge.yaml"
PACKAGE_NAME="microsoft-edge-canary"
REPO_ROOT_URL="https://packages.microsoft.com/repos/edge"
PACKAGES_GZ_URL="${REPO_ROOT_URL}/dists/stable/main/binary-amd64/Packages.gz"

if [[ ! -f "${MANIFEST_FILE}" ]]; then
  echo "Manifest not found: ${MANIFEST_FILE}" >&2
  exit 1
fi

# Read package metadata from the Debian Packages index (covered by repo signatures).
packages_data="$(curl -fsSL "${PACKAGES_GZ_URL}" | gzip -dc)"

candidates="$(awk -v pkg="${PACKAGE_NAME}" '
  BEGIN { RS=""; FS="\n" }
  {
    package=""; version=""; filename=""; sha256=""; size=""
    for (i = 1; i <= NF; i++) {
      line = $i
      if (line ~ /^Package: /) {
        package = substr(line, 10)
      } else if (line ~ /^Version: /) {
        version = substr(line, 10)
      } else if (line ~ /^Filename: /) {
        filename = substr(line, 11)
      } else if (line ~ /^SHA256: /) {
        sha256 = substr(line, 9)
      } else if (line ~ /^Size: /) {
        size = substr(line, 7)
      }
    }

    if (package == pkg && version != "" && filename != "" && sha256 != "" && size != "") {
      printf "%s\t%s\t%s\t%s\n", version, filename, sha256, size
    }
  }
' <<< "${packages_data}")"

if [[ -z "${candidates}" ]]; then
  echo "No candidates found for package ${PACKAGE_NAME}" >&2
  exit 1
fi

best_version=""
best_filename=""
best_sha256=""
best_size=""

while IFS=$'\t' read -r version filename sha256 size; do
  if [[ -z "${best_version}" ]] || dpkg --compare-versions "${version}" gt "${best_version}"; then
    best_version="${version}"
    best_filename="${filename}"
    best_sha256="${sha256}"
    best_size="${size}"
  fi
done <<< "${candidates}"

if [[ -z "${best_version}" ]]; then
  echo "Unable to determine latest ${PACKAGE_NAME} version" >&2
  exit 1
fi

best_url="${REPO_ROOT_URL}/${best_filename}"

echo "Latest ${PACKAGE_NAME}: ${best_version}"
echo "URL: ${best_url}"
echo "SHA256: ${best_sha256}"
echo "Size: ${best_size}"

export NEW_URL="${best_url}"
export NEW_SHA256="${best_sha256}"
export NEW_SIZE="${best_size}"

tmp_manifest="$(mktemp)"
in_extra_data=0
updated_block=0

while IFS= read -r line; do
  if [[ ${updated_block} -eq 0 && "${line}" =~ ^[[:space:]]*-[[:space:]]type:[[:space:]]*extra-data[[:space:]]*$ ]]; then
    in_extra_data=1
  elif [[ ${in_extra_data} -eq 1 && "${line}" =~ ^[[:space:]]*-[[:space:]]type:[[:space:]]* ]]; then
    in_extra_data=0
  fi

  if [[ ${in_extra_data} -eq 1 ]]; then
    if [[ "${line}" =~ ^([[:space:]]*)url:[[:space:]]+https://packages\.microsoft\.com/repos/edge/pool/main/m/microsoft-edge-canary/microsoft-edge-canary_[^[:space:]]+_amd64\.deb[[:space:]]*$ ]]; then
      line="${BASH_REMATCH[1]}url: ${NEW_URL}"
    elif [[ "${line}" =~ ^([[:space:]]*)sha256:[[:space:]]+[0-9a-f]{64}[[:space:]]*$ ]]; then
      line="${BASH_REMATCH[1]}sha256: ${NEW_SHA256}"
    elif [[ "${line}" =~ ^([[:space:]]*)size:[[:space:]]+[0-9]+[[:space:]]*$ ]]; then
      line="${BASH_REMATCH[1]}size: ${NEW_SIZE}"
      updated_block=1
      in_extra_data=0
    fi
  fi

  printf '%s\n' "${line}" >> "${tmp_manifest}"
done < "${MANIFEST_FILE}"

mv "${tmp_manifest}" "${MANIFEST_FILE}"

if git diff --quiet -- "${MANIFEST_FILE}"; then
  echo "No manifest changes were necessary."
else
  echo "Updated ${MANIFEST_FILE} with latest ${PACKAGE_NAME} metadata."
fi
