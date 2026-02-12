#!/bin/bash

# Script to copy pmm-smart-contract to tenbin-monorepo/contracts
# Preserves git history and excludes build artifacts

set -e

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONOREPO_DIR="/Users/calvinlin/tenbin-monorepo"
TARGET_DIR="${MONOREPO_DIR}/contracts"

echo "📦 Copying contracts to monorepo..."
echo "Source: ${SOURCE_DIR}"
echo "Target: ${TARGET_DIR}"

# Check if monorepo exists
if [ ! -d "${MONOREPO_DIR}" ]; then
    echo "❌ Error: ${MONOREPO_DIR} does not exist"
    exit 1
fi

# Create contracts directory if it doesn't exist
mkdir -p "${TARGET_DIR}"

# Copy everything except node_modules, cache, and artifacts (we'll handle git separately)
echo "📋 Copying files..."
rsync -av \
    --exclude='node_modules' \
    --exclude='cache' \
    --exclude='artifacts' \
    --exclude='.openzeppelin' \
    --exclude='out' \
    --exclude='.env.local' \
    --exclude='.git' \
    "${SOURCE_DIR}/" "${TARGET_DIR}/"

# Copy git history if .git exists in source
if [ -d "${SOURCE_DIR}/.git" ]; then
    echo "📚 Copying git history..."
    cp -r "${SOURCE_DIR}/.git" "${TARGET_DIR}/.git"
    # Update git config to reflect new location
    cd "${TARGET_DIR}"
    git config core.worktree "${TARGET_DIR}"
fi

echo "✅ Copy complete!"
echo ""
echo "Next steps:"
echo "1. cd ${TARGET_DIR}"
echo "2. Review and commit changes if needed"
echo "3. Update any path references in monorepo configs"
