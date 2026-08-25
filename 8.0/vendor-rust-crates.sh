#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SURICATA_RUST_DIR="${ROOT_DIR}/local-src/suricata-master/rust"
CARGO_HOME_DIR="${ROOT_DIR}/.cargo-vendor-home"

if [ ! -f "${SURICATA_RUST_DIR}/Cargo.toml" ]; then
    echo "ERROR: ${SURICATA_RUST_DIR}/Cargo.toml not found" >&2
    echo "Prepare local-src/suricata-master before running this script." >&2
    exit 1
fi

mkdir -p "${CARGO_HOME_DIR}"

cat > "${CARGO_HOME_DIR}/config.toml" <<'EOF'
[source.crates-io]
replace-with = "rsproxy"

[source.rsproxy]
registry = "sparse+https://rsproxy.cn/index/"

[net]
git-fetch-with-cli = true
retry = 10
EOF

cd "${SURICATA_RUST_DIR}"

echo "Using Cargo home: ${CARGO_HOME_DIR}"
echo "Vendoring Rust crates into: ${SURICATA_RUST_DIR}/vendor"
CARGO_HOME="${CARGO_HOME_DIR}" cargo vendor vendor

echo
echo "Rust crates vendored successfully."
echo "Suricata configure will enable rust/.cargo/config.toml automatically because rust/vendor exists."
