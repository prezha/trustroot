#!/bin/bash

set -ueo pipefail

root="${1:-}"
mirror="${2:-}"

# cleanup
rm -rf repository repository.tgz TrustRoot.yaml trustroot.log
rm -rf ~/.sigstore

if [[ -z "${root}" && -z "${mirror}" ]]; then
  echo "Using default public sigstore 'root' and 'mirror':"
  if ! root_status="$(cosign initialize 2>&1)"; then
    echo "Error: ${root_status}"
    exit 1
  fi
else
  echo "Using custom sigstore 'root':${root} and 'mirror':${mirror}:"
  if ! root_status="$(cosign initialize --root="${root}" --mirror="${mirror}" 2>&1)"; then
    echo "Error: ${root_status}"
    exit 1
  fi
fi

# extract json-only lines from cosign initialize output
# note: currently, it starts with a leading space - ie, ' {', and ends with '}'
if ! root_status_json="$(sed -n '/^ *{/,/^}/p' <<< "${root_status}")"; then
  echo "Error: could not extract json from cosign initialize output"
  exit 1
fi

echo -e "\ncosign Root status:\n${root_status_json}"

if ! remote="$(jq -r '.remote' <<< "${root_status_json}" 2>&1)"; then
  echo "Error: could not extract remote from cosign initialize output"
  exit 1
fi
echo -e "\nusing remote: ${remote}"

echo -e "\ndownloading metadata files:"

mkdir -p repository/targets

metadata="root.json snapshot.json targets.json timestamp.json"

for file in ${metadata}; do
  echo -n " - ${file} version: "
  if ! v="$(jq -r ".metadata.\"${file}\".version" <<< "${root_status_json}" 2>&1)"; then
    echo "Error: could not extract version for ${file} from cosign initialize output"
    exit 1
  fi
  echo -n "${v} ... "

  path="${v}.${file}"
  if [[ "${file}" == "timestamp.json" ]]; then
    path="timestamp.json"
  fi

  if ! curl -sSfLo "repository/${path}" "${remote}/${path}"; then
    echo "Error: could not download ${file} from ${remote}/${path}"
    exit 1
  fi

  # we'll need base64-encoded root.json later
  if [[ "${file}" == "root.json" ]]; then
    if ! b64_root_json="$(base64 -i "repository/${path}" 2>&1)"; then
      echo "Error: could not base64-encode root.json"
      exit 1
    fi
  fi

  echo "done"
done

echo -e "\ncopying targets from .sigstore to repository/targets using their respective sha256 and sha512:"

for sha_alg in 256 512; do
  for target in ~/.sigstore/root/targets/*; do
    echo -n " - ${target} -> "

    if ! out="$(shasum -a "${sha_alg}" "${target}" 2>&1)"; then
      echo "Error: could not calculate sha${sha_alg} for ${target}"
      exit 1
    fi

    sha="$(cut -d ' ' -f 1 <<< "${out}")"

    dest="repository/targets/${sha}.$(basename "${target}")"
    echo -n "${dest} ... "

    if ! cp "${target}" "${dest}"; then
      echo "Error: could not copy ${target} to ${dest}"
      exit 1
    fi
    echo "done"
  done
done

echo -ne "\ncompresing repository to repository.tgz ... "
if ! out="$(tar -czf repository.tgz repository 2>&1)"; then
  echo "Error: ${out}"
  exit 1
fi
echo "done"

if ! b64_repository_tgz="$(base64 -i repository.tgz 2>&1)"; then
  echo "Error: could not base64-encode repository.tgz"
  exit 1
fi
echo -e "\nusing base64 encoded repository.tgz: ${b64_repository_tgz}"

echo -e "\nusing base64 encoded root.json: ${b64_root_json}"

echo -e "\ngenerating TrustRoot.yaml:\n"

if ! cat <<EOF | tee TrustRoot.yaml
apiVersion: policy.sigstore.dev/v1alpha1
kind: TrustRoot
metadata:
  name: $(sed 's/.*https:\/\///' <<< "${remote}")-$(date +%s)
spec:
  repository:
    root: |-
      ${b64_root_json}
    mirrorFS: |-
      ${b64_repository_tgz}
EOF
then
  echo "Error: could not generate TrustRoot.yaml"
  exit 1
fi

echo -e "\ndone."

echo -e "\nUse 'kubectl apply -f TrustRoot.yaml' to deploy the TrustRoot."
