#!/bin/bash

# Constants
readonly DOWNLOAD_DIR="./download"
readonly RELEASE_DIR="./release"

mkdir -p "$RELEASE_DIR" "$DOWNLOAD_DIR"

# Colored output logs
green_log() {
	echo -e "\e[32m$1\e[0m"
}
red_log() {
	echo -e "\e[31m$1\e[0m"
}

#################################################

# Download GitHub assets requirement
# Usage: dl_gh <repo> <owner> <tag> [file_pattern] [output_name]
#   repo: Repository name (can be space-separated list for latest tag)
#   owner: GitHub owner/org name
#   tag: "latest", "prerelease", or specific tag
#   file_pattern: Optional regex pattern to filter assets (default: download all except .asc)
#   output_name: Optional output filename (for single file downloads with custom name)
#
# Examples:
#   dl_gh "revanced-patches" "revanced" "latest"
#   dl_gh "APKEditor" "REAndroid" "V1.4.7" ".*APKEditor-1\.4\.7\.jar$" "APKEditor.jar"
#   dl_gh "revanced-patches revanced-cli" "revanced" "prerelease"
dl_gh() {
	local repo="$1" owner="$2" tag="$3" file_pattern="$4" output_name="$5"
	local url

	# Handle prerelease tag
	if [[ $tag == "prerelease" ]]; then
		url=$(curl -s "https://api.github.com/repos/$owner/$repo/releases" |
			jq -r '[.[] | select(.prerelease == true)][0].url')
	else
		url="https://api.github.com/repos/$owner/$repo/releases/$([ "$tag" == "latest" ] && echo "latest" || echo "tags/$tag")"
	fi

	# Build jq filter based on file_pattern
	local jq_filter
	# shellcheck disable=SC2016  # We use --arg to pass file_pattern to jq
	if [[ -n $file_pattern ]]; then
		# Download only matching files (for single assets like APKEditor)
		jq_filter='.assets[] | select(.name | test($file_pattern)) |
		          "\(.browser_download_url) \(.name)"'
	else
		# Download all assets except .asc signatures
		jq_filter='.assets[] | select(.name | endswith(".asc") | not) |
		          "\(.browser_download_url) \(.name)"'
	fi

	# Get the list of assets (url name pairs)
	local assets
	assets=$(curl -s "$url" | jq -r --arg file_pattern "$file_pattern" "$jq_filter")

	# Download each asset
	while read -r url names; do
		green_log "[+] Downloading $names from $owner"
		if [[ -n $output_name ]]; then
			# Use custom output name for single file downloads
			curl -sL -o "$output_name" "$url"
		else
			# Use original filename for bulk downloads
			curl -sL -o "$names" "$url"
		fi
	done <<<"$assets"
}

#################################################

# Setup APKEditor for merging split APKs
APKEDITOR_VERSION="V1.4.7"
if [[ ! -f "./APKEditor.jar" ]]; then
	green_log "[+] Downloading APKEditor ${APKEDITOR_VERSION}"
	dl_gh "APKEditor" "REAndroid" "${APKEDITOR_VERSION}" ".*APKEditor-1\.4\.7\.jar$" "APKEditor.jar"
fi
APKEditor="./APKEditor.jar"

#################################################

# Get patches list:
get_patches_key() {
	excludePatches=""
	includePatches=""
	excludeLinesFound=false
	includeLinesFound=false

	# Remove carriage returns (cross-platform compatible)
	tr -d '\r' <"src/patches/$1/include-patches" >"src/patches/$1/.tmp_include"
	tr -d '\r' <"src/patches/$1/exclude-patches" >"src/patches/$1/.tmp_exclude"
	mv "src/patches/$1/.tmp_include" "src/patches/$1/include-patches"
	mv "src/patches/$1/.tmp_exclude" "src/patches/$1/exclude-patches"

	# Use CLI v5+ syntax: -d for disable, -e for enable
	while IFS= read -r line1; do
		excludePatches+=" -d \"$line1\""
		excludeLinesFound=true
	done <"src/patches/$1/exclude-patches"

	while IFS= read -r line2; do
		if [[ $line2 == *"|"* ]]; then
			patch_name="${line2%%|*}"
			options="${line2#*|}"
			includePatches+=" -e \"${patch_name}\" ${options}"
		else
			includePatches+=" -e \"$line2\""
		fi
		includeLinesFound=true
	done <"src/patches/$1/include-patches"

	if [ "$excludeLinesFound" = false ]; then
		excludePatches=""
	fi
	if [ "$includeLinesFound" = false ]; then
		includePatches=""
	fi
	export excludePatches
	export includePatches
}

#################################################

# Get compatible version from CLI patches list
get_version_from_cli() {
	local pkg="$1"
	java -jar ./*cli*.jar list-patches --with-packages --with-versions ./*.rvp |
		awk -v pkg="$pkg" '
			BEGIN { found = 0 }
			/^Index:/ { found = 0 }
			/Package name: / { if ($3 == pkg) { found = 1 } }
			/Compatible versions:/ {
				if (found) {
					getline
					latest_version = $1
					while (getline && $1 ~ /^[0-9]+\./) {
						latest_version = $1
					}
					print latest_version
					exit
				}
			}
		'
}

# Merge split APKs to standalone APK
merge_split_apks() {
	local base_name="$1" extension="$2"

	case "$extension" in
	apkm | xapk | zip)
		green_log "[+] Merging split APKs to standalone APK"
		java -jar "$APKEditor" m -i "$DOWNLOAD_DIR/${base_name}.${extension}" -o "$DOWNLOAD_DIR/${base_name}.apk" >/dev/null 2>&1
		;;
	esac
}

# Download APK using APKPure API directly (curl)
# Usage: download_apk <package_name> <output_name> [architecture] [version]
# Arguments:
#   $1 - package_name: Android package name (e.g., com.google.android.youtube)
#   $2 - output_name: Name to save the APK as (without extension)
#   $3 - architecture: Optional architecture (arm64-v8a, armeabi-v7a, x86, x86_64, all)
#   $4 - version: Optional version string (if not specified, auto-detects from CLI)
#
# Version handling:
#   1. If $4 (version) is passed: use that version (highest priority)
#   2. If lock_version=1 is set: download latest
#   3. Otherwise: auto-detect version from CLI patches
#
# Examples:
#   download_apk "com.google.android.youtube" "youtube"              # Auto-detect version
#   download_apk "com.google.android.youtube" "youtube" "arm64-v8a"  # Auto-detect, specific arch
#   download_apk "com.google.android.youtube" "youtube" "" "18.49.35"  # Specific version
#   lock_version=1 download_apk "com.google.android.youtube" "youtube"  # Latest version
download_apk() {
	local pkg="$1" base_name="$2" arch="${3:-all}" version="$4"

	if [ -z "$version" ] && [ "${lock_version:-0}" != "1" ]; then
		version=$(get_version_from_cli "$pkg")
	fi

	export version="$version"

	# Define user-agent and other headers
	local user_agent="Dalvik/2.1.0 (Linux; U; Android 16; Pixel 9 Build/BP4A.251205.006); APKPure/3.20.6309 (Aegon)"
	local device_info='{"device_info":{"abis":["arm64-v8a","armeabi-v7a","armeabi","x86","x86_64"],"language":"en-US","os_ver":"36"}}'

	# Query APKPure API for version list
	green_log "[+] Querying APKPure API for $base_name version: ${version:-latest} arch: $arch"
	local api_url="https://tapi.pureapk.com/v3/get_app_his_version?hl=en&package_name=${pkg}"
	local response
	response=$(curl -s -G "$api_url" \
		-H "user-agent: $user_agent" \
		-H "ual-access-businessid: projecta" \
		-H "ual-access-projecta: $device_info")

	if [ -z "$response" ]; then
		red_log "[-] No response from APKPure API for $base_name"
		return 1
	fi

	# Parse JSON response to find download URL
	local download_url apk_type matched_version
	local found_version=false

	# Extract download URL based on version preference
	if [[ -n $version ]] && [[ $version != "latest" ]]; then
		download_url=$(echo "$response" | jq -r --arg ver "$version" '
			.version_list[] | select(.version_name == $ver) | .asset.url // empty
		')
		apk_type=$(echo "$response" | jq -r --arg ver "$version" '
			.version_list[] | select(.version_name == $ver) | .asset.type // "APK"
		')
		if [[ -n $download_url ]]; then
			matched_version="$version"
			found_version=true
		else
			red_log "[-] Requested version $version not found, falling back to latest"
		fi
	fi

	# If version not found or not specified, use latest version
	if [[ $found_version == false ]]; then
		download_url=$(echo "$response" | jq -r '.version_list[0].asset.url // empty')
		apk_type=$(echo "$response" | jq -r '.version_list[0].asset.type // "APK"')
		matched_version=$(echo "$response" | jq -r '.version_list[0].version_name // "unknown"')
		if [[ -z $version ]] || [[ $version == "latest" ]]; then
			green_log "[+] Using latest version: $matched_version"
		else
			green_log "[+] Using latest version $matched_version (requested $version not available)"
		fi
	fi

	if [[ -z $download_url ]]; then
		red_log "[-] Could not find download URL for $base_name"
		red_log "[-] API response: $(echo "$response" | head -c 500)"
		return 1
	fi

	local extension
	if [[ $apk_type == "XAPK" ]]; then
		extension="xapk"
	else
		extension="apk"
	fi

	# For XAPK files, don't append architecture - they contain all architectures
	local output_file="${base_name}.${extension}"
	if [[ $extension != "xapk" ]] && [[ $arch != "all" ]] && [[ -n $arch ]]; then
		output_file="${base_name}-${arch}.${extension}"
	fi

	green_log "[+] Downloading $base_name ($matched_version) to $output_file"

	# Download to DOWNLOAD_DIR (stay in current directory for APKEditor access)
	if ! curl -sL -o "$DOWNLOAD_DIR/$output_file" "$download_url" -H "user-agent: $user_agent"; then
		red_log "[-] Failed to download $base_name"
		return 1
	fi

	# Merge XAPK to standalone APK immediately
	if [[ $extension == "xapk" ]]; then
		green_log "[+] Merging XAPK to standalone APK"
		local merge_output
		merge_output=$(java -jar "$APKEditor" m -i "$DOWNLOAD_DIR/$output_file" -o "$DOWNLOAD_DIR/${base_name}.apk" 2>&1)
		local merge_status=$?
		if [[ $merge_status -ne 0 ]]; then
			red_log "[-] Failed to merge XAPK"
			red_log "[-] APKEditor output: $(echo "$merge_output" | tail -5)"
			return 1
		fi
		rm -f "$DOWNLOAD_DIR/$output_file"
		output_file="${base_name}.apk"
		# XAPK files are universal - signal this via global variable
		export APK_IS_UNIVERSAL=1
	fi

	if [[ ! -f "$DOWNLOAD_DIR/$output_file" ]]; then
		red_log "[-] Downloaded file not found: $output_file"
		return 1
	fi

	green_log "[+] Successfully downloaded $base_name to $output_file"
	return 0
}

#################################################

# Clear GitHub Actions environment variables (needed for inotia CLI)
unset_github_env() {
	unset CI GITHUB_ACTION GITHUB_ACTIONS GITHUB_ACTOR GITHUB_ENV GITHUB_EVENT_NAME \
		GITHUB_EVENT_PATH GITHUB_HEAD_REF GITHUB_JOB GITHUB_REF GITHUB_REPOSITORY \
		GITHUB_RUN_ID GITHUB_RUN_NUMBER GITHUB_SHA GITHUB_WORKFLOW GITHUB_WORKSPACE \
		RUN_ID RUN_NUMBER
}

# Patching apps with Revanced CLI:
patch() {
	green_log "[+] Patching $1:"
	if [ -f "$DOWNLOAD_DIR/$1.apk" ]; then
		local p b m ks a pu opt force
		if [ "$3" = inotia ]; then
			p="patch " b="-p *.rvp" m="" a="" ks=" --keystore=./src/_ks.keystore" pu="--purge=true" opt="--legacy-options=./src/options/$2.json" force=" --force"
			echo "Patching with Revanced-cli inotia"
		elif [ "$3" = morphe ]; then
			p="patch " b="-p *.mpp" m="" a="" ks=" --keystore=./src/morphe.keystore --keystore-password=Morphe --keystore-entry-password=Morphe" pu="--purge=true" opt="" force=" --force"
			echo "Patching with Morphe"
		else
			# Use CLI v5+ syntax (current standard)
			p="patch " b="-p *.rvp" m="" a="" ks="ks" pu="--purge=true" opt="" force=" --force"
			echo "Patching with Revanced-cli version 5+"
		fi
		[ "$3" = inotia ] && unset_github_env
		eval java -jar ./*cli*.jar "$p""$b" "$m""$opt" --out="$RELEASE_DIR/$1-$2.apk""$excludePatches""$includePatches" --keystore=./src/"$ks".keystore "$pu""$force" "$a""$DOWNLOAD_DIR/$1.apk" || exit 1
		unset version lock_version excludePatches includePatches
	else
		red_log "[-] Not found $1.apk"
		exit 1
	fi
}

#################################################

split_editor() {
	if [[ -z $3 || -z $4 ]]; then
		green_log "[+] Merge splits apk to standalone apk"
		java -jar $APKEditor m -i "$DOWNLOAD_DIR/$1" -o "$DOWNLOAD_DIR/$1.apk" >/dev/null 2>&1
		return 0
	fi
	IFS=' ' read -r -a include_files <<<"$4"
	mkdir -p "$DOWNLOAD_DIR/$2"
	for file in "$DOWNLOAD_DIR/$1"/*.apk; do
		filename=$(basename "$file")
		basename_no_ext="${filename%.apk}"
		if [[ $filename == "base.apk" ]]; then
			cp -f "$file" "$DOWNLOAD_DIR/$2/" >/dev/null 2>&1
			continue
		fi
		if [[ $3 == "include" ]]; then
			pattern=" $basename_no_ext "
			if [[ " ${include_files[*]} " =~ $pattern ]]; then
				cp -f "$file" "$DOWNLOAD_DIR/$2/" >/dev/null 2>&1
			fi
		elif [[ $3 == "exclude" ]]; then
			pattern=" $basename_no_ext "
			if [[ ! " ${include_files[*]} " =~ $pattern ]]; then
				cp -f "$file" "$DOWNLOAD_DIR/$2/" >/dev/null 2>&1
			fi
		fi
	done

	green_log "[+] Merge splits apk to standalone apk"
	java -jar "$APKEditor" m -i "$DOWNLOAD_DIR/$2" -o "$DOWNLOAD_DIR/$2.apk" >/dev/null 2>&1
}

#################################################

# shellcheck disable=SC2034  # archs is used by scripts that source this file
archs=("arm64-v8a" "armeabi-v7a" "x86_64" "x86")

#################################################

# Architecture Processing Helpers

# Generate architecture-specific exclusion patterns
# Usage: get_arch_excludes "arm64-v8a"
# Returns: Space-separated list of split configs to exclude
get_arch_excludes() {
	local target_arch="$1"
	case "$target_arch" in
	arm64-v8a)
		echo "split_config.armeabi_v7a split_config.x86 split_config.x86_64"
		;;
	armeabi-v7a)
		echo "split_config.arm64_v8a split_config.x86 split_config.x86_64"
		;;
	x86)
		echo "split_config.arm64_v8a split_config.armeabi_v7a split_config.x86_64"
		;;
	x86_64)
		echo "split_config.arm64_v8a split_config.armeabi_v7a split_config.x86"
		;;
	all)
		echo "" # No exclusions for all-arch builds
		;;
	*)
		red_log "[-] Unknown architecture: $target_arch"
		return 1
		;;
	esac
}

# Generic architecture processing function
# Internal function used by process_architectures and process_lite_builds
_process_arch_builds() {
	local base_apk="$1" variant="$2" patch_key="$3" cli_mode="$4" archs_list="$5"
	local build_type="$6" # "standard" or "lite"

	for arch in $archs_list; do
		get_patches_key "$patch_key"

		if [[ $build_type == "lite" ]]; then
			green_log "[+] Processing lite build for $base_apk on $arch"
			local arch_normalized="${arch//-/_}"
			local includes="split_config.${arch_normalized} split_config.en split_config.xxxhdpi"
			split_editor "$base_apk" "${base_apk}-lite-${arch}" "include" "$includes"
			patch "${base_apk}-lite-${arch}" "$variant" "$cli_mode"
		elif [[ $arch == "all" ]]; then
			green_log "[+] Processing $base_apk for all architectures"
			patch "$base_apk" "$variant" "$cli_mode"
		elif [[ ${APK_IS_UNIVERSAL:-0} == 1 ]]; then
			green_log "[+] Processing universal $base_apk (from XAPK)"
			patch "$base_apk" "$variant" "$cli_mode"
			unset APK_IS_UNIVERSAL
			break
		else
			green_log "[+] Processing $base_apk for $arch"
			local excludes
			excludes=$(get_arch_excludes "$arch")
			split_editor "$base_apk" "${base_apk}-${arch}" "exclude" "$excludes"
			patch "${base_apk}-${arch}" "$variant" "$cli_mode"
		fi
	done
}

# Batch process multiple architectures for a base APK
# Usage: process_architectures "youtube" "revanced" "youtube-revanced" "" "arm64-v8a armeabi-v7a x86 x86_64"
# Args:
#   $1 - base_apk: Base APK name (without extension)
#   $2 - variant: Variant name (revanced, revanced-beta, etc.)
#   $3 - patch_key: Patch configuration key
#   $4 - cli_mode: Optional CLI mode (inotia, liso, or empty for standard)
#   $5 - archs: Space-separated architecture list (default: arm64-v8a armeabi-v7a x86 x86_64)
process_architectures() {
	_process_arch_builds "$1" "$2" "$3" "${4:-}" "${5:-arm64-v8a armeabi-v7a x86 x86_64}" "standard"
}

# Process lite builds (minimal splits with language/DPI)
# Usage: process_lite_builds "youtube" "revanced" "youtube-revanced" "" "arm64-v8a armeabi-v7a"
# Args:
#   $1 - base_apk: Base APK name (without extension)
#   $2 - variant: Variant name
#   $3 - patch_key: Patch configuration key
#   $4 - cli_mode: Optional CLI mode
#   $5 - archs: Space-separated architecture list for lite builds (default: arm64-v8a armeabi-v7a)
process_lite_builds() {
	_process_arch_builds "$1" "$2" "$3" "${4:-}" "${5:-arm64-v8a armeabi-v7a}" "lite"
}

#################################################
