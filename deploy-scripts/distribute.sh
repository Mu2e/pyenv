#!/bin/bash

#
# Distribute a Python environment 
# Samuel Grant 2025 (Modified for Pixi/Mu2e JupyterHub 2026)
# Modified further by Sophie Middleton 2026
#
# USAGE: 
# . distribute.sh -e myenv
# or 
# . distribute.sh -e myenv -y # (auto yes)
# or
# . distribute.sh # if the current active environment is the one to distribute

umask 0022

# System-level explicit configuration for Pixi engine
export CONDA_PKGS_DIRS="/home/sophie/conda"
alias conda="/opt/pixi/.pixi/envs/default/bin/conda"
alias mamba="/opt/pixi/.pixi/envs/default/bin/conda"

# Parse command line arguments
AUTO_YES=false
PROVIDED_ENV_NAME=""

show_help() {
    cat << EOF
Usage: source $0 [-y|--yes] [-e|--env ENV_NAME] [-p|--path] [-h|--help]
       . $0 [-y|--yes] [-e|--env ENV_NAME] [-p|--path] [-h|--help]

  -y, --yes        Automatically answer 'Y' to all prompts
  -e, --env        Specify environment name to distribute
  -p, --path       Specifiy the path to write the environment
  -h, --help       Show this help message

This script will:
1. Export the specified environment to YAML (using Pixi's conda engine)
2. Directly archive the user's environment to bypass system permissions
3. Extract it to the target shared directory and manually fix binary prefixes

Examples:
  source $0 -e myenv       # Distribute 'myenv' environment
  . $0 -y -e myenv         # Auto-yes mode
  source $0                # Interactive mode (will prompt for env)

Note: This script must be sourced, not executed directly.
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -y|--yes)
            AUTO_YES=true
            shift
            ;;
        -e|--env)
            if [[ -z "${2:-}" ]]; then
                echo "❌ Error: --env requires a value" >&2
                return 1
            fi
            PROVIDED_ENV_NAME="$2"
            shift 2
            ;;
        -p|--path)
            PROVIDED_PATH="$2" 
            shift 2 
            ;;
        -h|--help)
            show_help
            return 0
            ;;
        *)
            echo "❌ Unknown option: $1" >&2
            echo "Use -h or --help for usage information" >&2
            return 1
            ;;
    esac
done

# Function to prompt user or auto-continue
prompt_continue() {
    local message="$1"
    local response
    
    if [[ "$AUTO_YES" == true ]]; then
        echo "$message [Y/n]: Y (auto)"
        return 0
    fi
    
    while true; do
        read -r -p "$message [Y/n]: " response
        case "$response" in
            [Yy]|[Yy][Ee][Ss]|"")  # Accept Y, y, yes, Yes, or empty (default to yes)
                return 0
                ;;
            [Nn]|[Nn][Oct])
                echo "❌ Exiting..."
                return 1
                ;;
            *)
                echo "Please answer Y or n"
                ;;
        esac
    done
}

# 1. Setup and validation
echo "⭐️ Environment distribution setup"

# Target environment validation mapping
if [[ -n "$PROVIDED_ENV_NAME" ]]; then
    ENV_NAME="$PROVIDED_ENV_NAME"
    echo "✅ Using specified environment: ${ENV_NAME}"
else
    ENV_NAME=${CONDA_DEFAULT_ENV:-}
    if [[ -z "$ENV_NAME" || "$ENV_NAME" == "base" ]]; then
        echo "⚠️  No environment specified via flags. Checking default home directories..."
        echo "Available environments in user space:"
        ls -1 /home/sophie/.conda/envs/ 2>/dev/null
        
        while true; do
            read -r -p "👋 Enter environment name to distribute: " ENV_NAME
            if [[ -n "$ENV_NAME" && -d "/home/sophie/.conda/envs/${ENV_NAME}" ]]; then
                echo "✅ Will distribute environment: ${ENV_NAME}"
                break
            else
                echo "❌ Environment folder does not exist in /home/sophie/.conda/envs/"
            fi
        done
    else
        echo "✅ Using currently active environment context: ${ENV_NAME}" 
    fi
fi

# Define explicit user paths to cross-reference
ABS_ENV_SOURCE="/home/sophie/.conda/envs/${ENV_NAME}"
if [[ ! -d "$ABS_ENV_SOURCE" ]]; then
    echo "❌ Error: Could not locate source directory at $ABS_ENV_SOURCE" >&2
    return 1
fi

PYENV_PATH="${PROVIDED_PATH:-/exp/mu2e/data/users/${USER}/pyenv}"
echo "✅ Using path: ${PYENV_PATH}"

ENV_DIR="${PYENV_PATH}/env"
YAML_DIR="${PYENV_PATH}/yml/full"
TAR_DIR="${PYENV_PATH}/tar"

# Create target deployment directories if they don't exist
for dir in "$ENV_DIR" "$YAML_DIR" "$TAR_DIR"; do
    if [[ ! -d "$dir" ]]; then
        echo "📁 Creating directory: $dir"
        mkdir -p "$dir"
    fi
done

if ! prompt_continue "👋 Distribute '${ENV_NAME}'?"; then
    return 1
fi

# 2. Create YAML
echo "⭐️ Exporting environment"
THIS_YAML="${YAML_DIR}/${ENV_NAME}.yml"

if [[ -f "${THIS_YAML}" ]]; then 
    if ! prompt_continue "👋 ${THIS_YAML} already exists. Overwrite?"; then
        return 1
    fi
    echo "🗑️  Removing existing ${THIS_YAML}..."
    rm -f "${THIS_YAML}"
fi

echo "📄 Exporting to YAML: ${THIS_YAML}"
# Execute export via the explicit Pixi wrapper mapping
if ! /opt/pixi/.pixi/envs/default/bin/conda env export --prefix "$ABS_ENV_SOURCE" > "${THIS_YAML}"; then
    echo "❌ Failed to export environment to YAML" >&2
    return 1
fi

# Remove prefix line (last line)
if ! sed '$d' "${THIS_YAML}" > "${THIS_YAML}.tmp"; then
    echo "❌ Failed to process YAML file" >&2
    return 1
fi

# Replace pyutils library line with GitHub URL
sed -i 's/- pyutils==\([0-9\.]*\)/- "git+https:\/\/github.com\/Mu2e\/pyutils.git"/' "${THIS_YAML}.tmp"

# Overwrite original file
if ! mv "${THIS_YAML}.tmp" "${THIS_YAML}"; then
    echo "❌ Failed to update YAML file" >&2
    return 1
fi

echo "✅ Written YAML: ${THIS_YAML}"

# 3. Direct Archiving and Relocation Pipeline
echo "⭐️ Packing environment"
PACKED_DIR="${ENV_DIR}/${ENV_NAME}"

if ! prompt_continue "👋 Copy and relocate '${ENV_NAME}' into '${PACKED_DIR}'?"; then
    return 1
fi

# Remove existing packed directory
if [[ -d "$PACKED_DIR" ]]; then 
    if ! prompt_continue "👋 ${PACKED_DIR} already exists. Remove and recreate?"; then
        return 1
    fi
    echo "🗑️  Removing existing ${PACKED_DIR}..."
    rm -rf "${PACKED_DIR}"
fi

# Remove existing tar file
TAR_FILE="${TAR_DIR}/${ENV_NAME}.tar.gz"
if [[ -f "${TAR_FILE}" ]]; then 
    if ! prompt_continue "👋 ${TAR_FILE} already exists. Overwrite?"; then
        return 1
    fi
    echo "🗑️  Removing existing tar file ${TAR_FILE}..."
    rm -f "${TAR_FILE}"
fi

echo "📦 Archiving directly from user space: ${ABS_ENV_SOURCE}..."
if ! tar -czf "${TAR_FILE}" -C "${ABS_ENV_SOURCE}" .; then
    echo "❌ Failed to package environment files" >&2
    return 1
fi

# Set proper filesystem permissions
chmod 644 "${TAR_FILE}"
echo "✅ Created tar file: ${TAR_FILE}"

echo "📂 Extracting '${TAR_FILE}' into target storage folder '${PACKED_DIR}'..."
if ! mkdir -p "${PACKED_DIR}"; then
    echo "❌ Failed to create target destination directory: ${PACKED_DIR}" >&2
    return 1
fi

if ! tar -xzf "${TAR_FILE}" -C "${PACKED_DIR}"; then
    echo "❌ Failed to unpack data into destination folder" >&2
    return 1
fi

# 4. Manual Text/Binary Prefix Patching (Bypassing conda-unpack)
echo "🔧 Fixing hardcoded prefixes manually..."
# Replaces references to the home directory path with the new destination path inside binary/text wrappers
find "${PACKED_DIR}/bin" -type f -exec grep -Iq . {} \; -and -exec sed -i "s|${ABS_ENV_SOURCE}|${PACKED_DIR}|g" {} +

echo ""
echo "✅ Completed successfully!"
echo "📁 Target shared environment directory: ${PACKED_DIR}"
echo "📄 Portable YAML configuration file: ${THIS_YAML}"
echo "📦 Distributable Tar package archive: ${TAR_FILE}"
echo ""
echo "To map systems or nodes over to this distributed environment:"
echo "  1. Update your shell context prefix: export CONDA_PREFIX=\"${PACKED_DIR}\""
echo "  2. Source your experiment setup function: setup_mu2e_python_env"
echo ""
