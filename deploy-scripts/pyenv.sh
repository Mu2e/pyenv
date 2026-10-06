#!/bin/bash

pyenvUsage() {
    cat << EOF

    Usage: muse activate ENV_NAME [VERSION]

    Activates a Mu2e Python environment (Supports Pixi and Conda builds).
    
    Available environments:
      • ana     - Standard analysis environment
      • rootana - Analysis environment with pyROOT support
    
    Parameters:
      ENV_NAME - Required: Environment name ('ana' or 'rootana')
      VERSION  - Optional: Environment version (default: 'current')
    
    Examples:
      pyenv ana
      pyenv ana 2.1.0
      pyenv rootana current

    See https://mu2ewiki.fnal.gov/wiki/Elastic_Analysis_Facility_(EAF)#Change_log for version info 

EOF
    return
}

# Show usage information if -h or no args
if [[ "$1" == "-h" || "$1" == "--help" || "$1" == "help" || $# -eq 0 ]]; then
    pyenvUsage
    return 0
fi

# Unset the help function 
unset -f pyenvUsage 

# ---------------------------------------------------------------------
# SAFE CVMFS FALLBACK CHECK
# ---------------------------------------------------------------------
if [ -z "$MU2E" ]; then
    export MU2E="/cvmfs/mu2e.opensciencegrid.org"
fi

# Parse command line arguments
ENVNAME=${1}
VERSION=${2:-current}
if [ "$VERSION" == "current" ]; then  # use current version link
    VERSION="$(readlink ${MU2E}/env/${ENVNAME}/current)"
fi

# Define paths
CONDA_PREFIX="${MU2E}/env/${ENVNAME}/${VERSION}"
ACTIVATE_PATH="${CONDA_PREFIX}/bin/activate"
DEACTIVATE_PATH="${CONDA_PREFIX}/bin/deactivate"

# Verify the environment directory actually exists
if [ ! -d "$CONDA_PREFIX" ]; then
    echo "ERROR - Mu2e Python environment directory not found!"
    echo "Path: $CONDA_PREFIX"
    return 1
fi

export pyenv_NAME="$ENVNAME"
export pyenv_VERSION="$VERSION"
export CONDA_PREFIX="$CONDA_PREFIX"

# ---------------------------------------------------------------------
# HYBRID ACTIVATION CHECK
# ---------------------------------------------------------------------
if [ -f "$ACTIVATE_PATH" ]; then
    echo "Activating Mu2e Python environment: $ENVNAME $VERSION (Legacy Conda build)"
    source "$ACTIVATE_PATH"
else
    echo "Activating Mu2e Python environment: $ENVNAME $VERSION (Pixi-Pack build)"
    # Pixi needs its bin path manually prioritized right away
    export PATH="$CONDA_PREFIX/bin:$PATH"
fi

# =====================================================================
# INTEGRATED PATH CLEANING & COMMAND PROTECTION
# =====================================================================
setup_mu2e_python_env() {
    # Clean and prioritize PATH
    PATH=$(echo "$PATH" | tr ':' '\n' | grep -v "$CONDA_PREFIX" | tr '\n' ':' | sed 's/:$//')
    export PATH="$CONDA_PREFIX/bin:$PATH"
    
    # Clean and prioritize PYTHONPATH
    PYTHONPATH=$(echo "$PYTHONPATH" | tr ':' '\n' | grep -v "$CONDA_PREFIX" | tr '\n' ':' | sed 's/:$//')
    export PYTHONPATH="$CONDA_PREFIX/lib/python3.12/site-packages:$PYTHONPATH"
    
    # Clean and prioritize JUPYTER_PATH
    JUPYTER_PATH=$(echo "$JUPYTER_PATH" | tr ':' '\n' | grep -v "$CONDA_PREFIX" | tr '\n' ':' | sed 's/:$//')
    export JUPYTER_PATH="$CONDA_PREFIX/share/jupyter/kernels:$JUPYTER_PATH"

    # Graphics, UI & Fonts
    export QT_QPA_PLATFORM_PLUGIN_PATH="$CONDA_PREFIX/lib/qt6/plugins/platforms"
    export FONTCONFIG_FILE="$CONDA_PREFIX/etc/fonts/fonts.conf"

    # SSL Cert allocations for locked down network nodes
    export GIT_SSL_CAINFO="$CONDA_PREFIX/ssl/cacert.pem"
    export SSL_CERT_FILE="$CONDA_PREFIX/ssl/cacert.pem"
    export CURL_CA_BUNDLE="$CONDA_PREFIX/ssl/cacert.pem"

    # Terminal UI and ROOT system roots
    export TERMINFO="$CONDA_PREFIX/share/terminfo"
    export CONDA_BUILD_SYSROOT="$CONDA_PREFIX/x86_64-conda-linux-gnu/sysroot"

    # Logging Suppressions
    export TF_CPP_MIN_LOG_LEVEL=3
    export ZFIT_DISABLE_TF_WARNINGS=1
    
    # Dynamic Library Binding
    LD_LIBRARY_PATH=$(echo "$LD_LIBRARY_PATH" | tr ':' '\n' | grep -v "$CONDA_PREFIX" | tr '\n' ':' | sed 's/:$//')
    export LD_LIBRARY_PATH="$CONDA_PREFIX/lib:$LD_LIBRARY_PATH"
}

# Run the runtime path-cleanup sequence immediately on sourcing
setup_mu2e_python_env

# Inject hidden protective command interception wrappers
for cmd in python pip jupyter conda mamba; do
    eval "${cmd}() {
        setup_mu2e_python_env
        command ${cmd} \"\$@\"
    }"
    export -f "$cmd"
done

export -f setup_mu2e_python_env
# =====================================================================

# Setup deactivate function safely
deactivate() {
    # If a native Conda deactivate tracker file exists, run it
    if [ -f "$DEACTIVATE_PATH" ]; then
        source "$DEACTIVATE_PATH"
    else
        # Fall back to manual path stripping for Pixi environments
        PATH=$(echo "$PATH" | tr ':' '\n' | grep -v "$CONDA_PREFIX" | tr '\n' ':' | sed 's/:$//')
        PYTHONPATH=$(echo "$PYTHONPATH" | tr ':' '\n' | grep -v "$CONDA_PREFIX" | tr '\n' ':' | sed 's/:$//')
        JUPYTER_PATH=$(echo "$JUPYTER_PATH" | tr ':' '\n' | grep -v "$CONDA_PREFIX" | tr '\n' ':' | sed 's/:$//')
        LD_LIBRARY_PATH=$(echo "$LD_LIBRARY_PATH" | tr ':' '\n' | grep -v "$CONDA_PREFIX" | tr '\n' ':' | sed 's/:$//')
        export PATH PYTHONPATH JUPYTER_PATH LD_LIBRARY_PATH
        
        if type conda_deactivate >/dev/null 2>&1; then conda_deactivate; fi
        if type python_deactivate >/dev/null 2>&1; then python_deactivate; fi
    fi
    
    # Tear down function wrappers completely to restore clean system shell state
    for cmd in python pip jupyter conda mamba; do
        unset -f "$cmd"
    done
    unset -f setup_mu2e_python_env
    
    # Reset tracking environment variables
    unset pyenv_NAME
    unset pyenv_VERSION
    unset CONDA_PREFIX
    
    echo "Deactivated Mu2e Environment."
    unset -f deactivate
}

echo "Run 'deactivate' to exit the environment" 
return 0
