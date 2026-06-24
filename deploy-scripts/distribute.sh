#!/bin/bash

#
# Distribute a Pixi/Conda Python environment 
# Samuel Grant 2025 / Sophie Middleton 2026
# Downstream tool optimized for EAF GPU Compute Nodes & Data Cluster Storage
#
# USAGE: 
# . distribute.sh -e myenv -p /exp/mu2e/data/users/${USER}/pyenv
#

umask 0022

# System-level explicit configuration for Pixi engine
PIXI_EXEC="/opt/pixi/.pixi/envs/default/bin/pixi"
pixi() { "$PIXI_EXEC" "$@"; }

# Initialize variables
AUTO_YES=false
PROVIDED_ENV_NAME=""
PROVIDED_PATH=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -y|--yes) AUTO_YES=true; shift ;;
        -e|--env)
            if [[ -z "${2:-}" ]]; then
                echo "❌ Error: --env requires a value" >&2
                return 1
            fi
            PROVIDED_ENV_NAME="$2"; shift 2 ;;
        -p|--path)
            if [[ -z "${2:-}" ]]; then
                echo "❌ Error: --path requires a value" >&2
                return 1
            fi
            PROVIDED_PATH="$2"; shift 2 ;;
        -h|--help)
            cat << EOF
Usage: source $0 [-y|--yes] [-e|--env ENV_NAME] [-p|--path DATA_TARGET_PATH]
This script takes an environment built by build.sh on the local EAF node, 
safely packages its assets (including custom sitecustomize and kernel maps),
and exports it permanently to the data cluster storage mount.
EOF
            return 0 ;;
        *) echo "❌ Unknown option: $1" >&2; return 1 ;;
    esac
done

prompt_continue() {
    local message="$1"; local response
    if [[ "$AUTO_YES" == true ]]; then echo "$message [Y/n]: Y (auto)"; return 0; fi
    while true; do
        read -r -p "$message [Y/n]: " response
        case "$response" in
            [Yy]|[Yy][Ee][Ss]|"") return 0 ;;
            [Nn]|[Nn][Oo]) echo "❌ Exiting..." ; return 1 ;;
            *) echo "Please answer Y or n" ;;
        esac
    done
}

echo "⭐️ EAF Environment Relocation Pipeline"

# 1. Detect and Validate the Active Environment Built by build.sh
if [[ -n "$PROVIDED_ENV_NAME" ]]; then
    ENV_NAME="$PROVIDED_ENV_NAME"
else
    ENV_NAME=${CONDA_DEFAULT_ENV:-}
    if [[ -z "$ENV_NAME" || "$ENV_NAME" == "base" ]]; then
        echo "❌ Error: No active environment detected. Run 'conda activate your_env' or specify with -e." >&2
        return 1
    fi
fi
echo "✅ Context Environment Target: ${ENV_NAME}"

# Read current active prefix where build.sh placed things
ABS_ENV_SOURCE="${CONDA_PREFIX}"
if [[ -z "$ABS_ENV_SOURCE" || ! -d "$ABS_ENV_SOURCE" ]]; then
    echo "❌ Error: CONDA_PREFIX is invalid. Ensure your environment is actively turned on." >&2
    return 1
fi
echo "✅ Source Path Located: ${ABS_ENV_SOURCE}"

# 2. Setup Destination Paths on the Data Machine
PYENV_PATH="${PROVIDED_PATH:-/exp/mu2e/data/users/${USER}/pyenv}"
ENV_DIR="${PYENV_PATH}/env"
YAML_DIR="${PYENV_PATH}/yml/full"
TAR_DIR="${PYENV_PATH}/tar"
FINAL_PACKED_DIR="${ENV_DIR}/${ENV_NAME}"

# Ensure data machine infrastructure paths exist
mkdir -p "$ENV_DIR" "$YAML_DIR" "$TAR_DIR"

if ! prompt_continue "👋 Relocate and distribute '${ENV_NAME}' out to the Data Cluster?"; then
    return 1
fi

# Clean up data targets if overwriting an old version
if [[ -d "$FINAL_PACKED_DIR" ]]; then
    if ! prompt_continue "⚠️  ${FINAL_PACKED_DIR} already exists on the data machine. Wipe and overwrite?"; then
        return 1
    fi
    echo "🗑️  Clearing outdated directory on data cluster..."
    rm -rf "${FINAL_PACKED_DIR}"
fi

# 3. Create Ported YAML
echo "⭐️ Exporting Configuration Mapping"
THIS_YAML="${YAML_DIR}/${ENV_NAME}.yml"
rm -f "${THIS_YAML}" 2>/dev/null

if ! conda env export > "${THIS_YAML}"; then
    echo "❌ Failed to export environment configuration to YAML" >&2
    return 1
fi

# Sanitize trailing local system configurations from the YAML file
sed -i '$d' "${THIS_YAML}"
sed -i 's/- pyutils==.*/- "git+https:\/\/github.com\/Mu2e\/pyutils.git"/' "${THIS_YAML}"
echo "✅ Configuration YAML documented: ${THIS_YAML}"

# 4. Local Packaging to Preserve Symlinks and Meta-structures
# To move massive GPU directories across the network mount to the data machine without
# breaking symlinks or hitting small-file creation bottlenecks, we tar it locally.
TAR_FILE="${TAR_DIR}/${ENV_NAME}.tar.gz"
rm -f "${TAR_FILE}" 2>/dev/null

echo "📦 Archiving environment files on EAF fast local space..."
if ! tar -czf "${TAR_FILE}" -C "${ABS_ENV_SOURCE}" .; then
    echo "❌ Error: Failed to build archive package." >&2
    return 1
fi
chmod 644 "${TAR_FILE}"
echo "✅ Compressed archive staged: ${TAR_FILE}"

# 5. Extract Directly to Target Data Machine Location
echo "📂 Unpacking data package straight onto Data Cluster..."
mkdir -p "${FINAL_PACKED_DIR}"
if ! tar -xzf "${TAR_FILE}" -C "${FINAL_PACKED_DIR}"; then
    echo "❌ Error: Failed network extraction step to the Data Cluster." >&2
    return 1
fi

# 6. Safe Text Prefix Adjustment for Final Path Relocation
# Because build.sh wrote things tracking your local EAF build directory, we run a safe text sweep
# to redirect shebang lines, kernel paths, and activate files to point to the long-term Data Cluster path.
echo "🔧 Re-aligning script prefixes for new storage target..."
find "${FINAL_PACKED_DIR}" -type f ! -name "*.so" ! -name "*.dylib" -exec file {} \; | grep -i "text" | cut -d: -f1 | while read -r text_file; do
    sed -i "s|${ABS_ENV_SOURCE}|${FINAL_PACKED_DIR}|g" "$text_file" 2>/dev/null
done

echo ""
echo "✅ Relocation and Distribution completed successfully!"
echo "📁 Data Cluster Target: ${FINAL_PACKED_DIR}"
echo "📄 Portable Configuration: ${THIS_YAML}"
echo "📦 Archive Tarball Backup: ${TAR_FILE}"
echo ""
echo "💡 To load this distributed environment inside your cluster workflows:"
echo "   source ${FINAL_PACKED_DIR}/bin/activate"
echo ""

