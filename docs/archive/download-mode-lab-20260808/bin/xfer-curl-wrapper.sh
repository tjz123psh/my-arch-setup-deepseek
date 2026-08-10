#!/usr/bin/env bash
set -Eeuo pipefail
url=${1:?missing URL}
out=${2:?missing output path}
log=${DOWNLOAD_MODE_XFER_LOG:?missing DOWNLOAD_MODE_XFER_LOG}
printf '%s\t%s\t%s\n' start "${url}" "${out}" >>"${log}"
/usr/bin/curl --fail --silent --show-error --location --connect-timeout 4 --max-time 30 -o "${out}" "${url}"
printf '%s\t%s\t%s\n' end "${url}" "${out}" >>"${log}"
