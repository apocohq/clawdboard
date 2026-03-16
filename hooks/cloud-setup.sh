#!/bin/bash
# Clawdboard Cloud VM Setup Script
# This script is designed to be pasted into the claude.ai Setup Script field.
# It installs the Clawdboard hook with cloud push support.
#
# Prerequisites:
# - CLAWDBOARD_KEY environment variable must be set to your public key

set -e

if [ -z "$CLAWDBOARD_KEY" ]; then
    echo "Warning: CLAWDBOARD_KEY not set. Cloud push will be disabled."
    echo "Set it in your claude.ai environment variables."
fi

# Install cryptography package for ECIES encryption
pip install -q cryptography 2>/dev/null || pip3 install -q cryptography 2>/dev/null || true

# Create directories
mkdir -p ~/.clawdboard/hooks ~/.clawdboard/sessions

echo "Clawdboard cloud hook setup complete"
