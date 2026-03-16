#!/bin/bash
# Clawdboard Cloud VM Setup Script
# This script is designed to be pasted into the claude.ai Setup Script field.
# It installs the Clawdboard hook with cloud push support.
#
# Prerequisites:
# - CLAWDBOARD_KEY environment variable must be set to your public key

set -e

if [ -z "$CLAWDBOARD_KEY" ]; then
    echo "ERROR: CLAWDBOARD_KEY not set. Cloud push will not work."
    echo "Set it in your claude.ai environment variables."
    exit 1
fi

# Install cryptography package for ECIES encryption
pip install -q cryptography 2>/dev/null || pip3 install -q cryptography 2>/dev/null || {
    echo "ERROR: Failed to install 'cryptography' package. Cloud push requires it."
    exit 1
}

# Verify the import actually works
python3 -c "from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey" 2>/dev/null || {
    echo "ERROR: 'cryptography' installed but import failed. Check Python environment."
    exit 1
}

# Create directories
mkdir -p ~/.clawdboard/hooks ~/.clawdboard/sessions

echo "Clawdboard cloud hook setup complete"
