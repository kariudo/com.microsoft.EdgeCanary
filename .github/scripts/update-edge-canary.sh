#!/usr/bin/env bash
set -euo pipefail

MANIFEST_FILE="com.microsoft.Edge.yaml"
METAINFO_FILE="com.microsoft.Edge.metainfo.xml"
PACKAGE_NAME="microsoft-edge-canary"
REPO_ROOT_URL="https://packages.microsoft.com/repos/edge"
PACKAGES_GZ_URL="${REPO_ROOT_URL}/dists/stable/main/binary-amd64/Packages.gz"

if [[ ! -f "${MANIFEST_FILE}" ]]; then
  echo "Manifest not found: ${MANIFEST_FILE}" >&2
  exit 1
fi

if [[ ! -f "${METAINFO_FILE}" ]]; then
  echo "Metainfo not found: ${METAINFO_FILE}" >&2
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
export NEW_VERSION="${best_version}"

release_date="$(date -u +%F)"
new_major="${NEW_VERSION%%.*}"

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

tmp_metainfo="$(mktemp)"
in_releases=0
updated_release=0
first_release_seen=0
re_releases_open='^[[:space:]]*<releases>[[:space:]]*$'
re_release_line='^([[:space:]]*)<release[[:space:]]+version="([^"]+)"[[:space:]]+date="([^"]+)"([^>]*)>[[:space:]]*$'
re_releases_close='^[[:space:]]*</releases>[[:space:]]*$'

while IFS= read -r line; do
  if [[ ${in_releases} -eq 0 && "${line}" =~ ${re_releases_open} ]]; then
    in_releases=1
    printf '%s\n' "${line}" >> "${tmp_metainfo}"
    continue
  fi

  if [[ ${in_releases} -eq 1 && ${first_release_seen} -eq 0 && "${line}" =~ ${re_release_line} ]]; then
    indent="${BASH_REMATCH[1]}"
    current_version="${BASH_REMATCH[2]}"
    current_major="${current_version%%.*}"

    if [[ "${current_major}" == "${new_major}" ]]; then
      line="${line/version=\"${current_version}\"/version=\"${NEW_VERSION}\"}"
      line="${line/date=\"${BASH_REMATCH[3]}\"/date=\"${release_date}\"}"
      printf '%s\n' "${line}" >> "${tmp_metainfo}"
    else
      printf '%s\n' "${indent}<release version=\"${NEW_VERSION}\" date=\"${release_date}\">" >> "${tmp_metainfo}"
      printf '%s\n' "${indent}  <description/>" >> "${tmp_metainfo}"
      printf '%s\n' "${indent}</release>" >> "${tmp_metainfo}"
      printf '%s\n' "${line}" >> "${tmp_metainfo}"
    fi

    first_release_seen=1
    updated_release=1
    continue
  fi

  if [[ ${in_releases} -eq 1 && ${first_release_seen} -eq 0 && "${line}" =~ ${re_releases_close} ]]; then
    printf '%s\n' "    <release version=\"${NEW_VERSION}\" date=\"${release_date}\">" >> "${tmp_metainfo}"
    printf '%s\n' "      <description/>" >> "${tmp_metainfo}"
    printf '%s\n' "    </release>" >> "${tmp_metainfo}"
    first_release_seen=1
    updated_release=1
  fi

  if [[ ${in_releases} -eq 1 && "${line}" =~ ${re_releases_close} ]]; then
    in_releases=0
  fi

  printf '%s\n' "${line}" >> "${tmp_metainfo}"
done < "${METAINFO_FILE}"

mv "${tmp_metainfo}" "${METAINFO_FILE}"

if [[ ${updated_release} -eq 0 ]]; then
  echo "Warning: no <release> entry was updated in ${METAINFO_FILE}" >&2
fi

if git diff --quiet -- "${MANIFEST_FILE}" "${METAINFO_FILE}"; then
  echo "No manifest or metainfo changes were necessary."
else
  echo "Updated ${MANIFEST_FILE} and ${METAINFO_FILE} with latest ${PACKAGE_NAME} metadata."
fi
