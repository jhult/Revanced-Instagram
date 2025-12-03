#!/bin/bash
# Revanced build
source ./src/build/utils.sh
# Download requirements
dl_gh "revanced-patches revanced-cli" "revanced" "latest"

get_patches_key "instagram"
get_apkpure "com.instagram.android" "instagram-arm64-v8a" "instagram-android/com.instagram.android" "Bundle"
patch "instagram-arm64-v8a" "revanced"
