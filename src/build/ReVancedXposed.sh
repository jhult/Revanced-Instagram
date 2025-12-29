#!/bin/bash
# ReVancedXposed build (uses LSPatch, not ReVanced CLI)
# NOTE: This is a special case - uses Xposed framework, not unified build system
source ./src/build/utils.sh
#################################################

# Download requirements
j="i"
dl_gh "ReVancedXposed_Spot${j}fy" "chsbuffer" "latest"
dl_gh "LSPatch" "JingMatrix" "latest"
#################################################

# Download Spotjfy APK (using unified download_apk function)
download_apk "com.spot${j}fy.music" "spotjfy"

# Patch Spotjfy with LSPatch
green_log "[+] Patching with LSPatch..."
java -jar lspatch.jar ./download/spotjfy.apk \
	-k ./src/fiorenmas.ks \
	fiorenmas fiorenmas fiorenmas \
	-m ReVancedXposed*.apk \
	-o ./release/

# Rename output
mv ./release/spotjfy-*-lspatched.apk ./release/spotjfy-ReVancedXposed.apk

green_log "[+] Successfully built spotjfy-ReVancedXposed.apk"
