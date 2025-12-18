#!/bin/bash
# Revanced build
source ./src/build/utils.sh
# Download requirements
dl_gh "revanced-patches revanced-cli" "revanced" "latest"

get_patches_key "instagram"
# Force using latest version from APKPure instead of constrained version from patches
lock_version=1
get_apkpure "com.instagram.android" "instagram-arm64-v8a" "instagram-android/com.instagram.android" "Bundle"
patch "instagram-arm64-v8a" "revanced"
