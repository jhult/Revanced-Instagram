#!/bin/bash
# Unified Revanced Build Script
# Replaces: Revanced.sh, Revanced-Beta.sh, Revanced-Extended.sh, etc.
# Usage: ./build-unified.sh <variant> <app_name>
#   variant: revanced, revanced-beta, revanced-extended, etc. (from variants.conf)
#   app_name: youtube, instagram, spotify, etc. (from apps.conf display_name field)

set -e

# shellcheck disable=SC1091  # utils.sh is in the same directory
source "$(dirname "$0")/utils.sh"

# Configuration files
VARIANTS_CONF="$(dirname "$0")/../config/variants.conf"
APPS_CONF="$(dirname "$0")/../config/apps.conf"

#################################################

# Parse variant configuration from variants.conf
# Sets global variables: VARIANT_NAME, PATCHES_REPO, PATCHES_OWNER, etc.
parse_variant_config() {
	local variant_id="$1"

	if [[ ! -f $VARIANTS_CONF ]]; then
		red_log "[-] Variants configuration file not found: $VARIANTS_CONF"
		exit 1
	fi

	while IFS='|' read -r vid name patches_repo patches_owner patches_tag cli_repo cli_owner cli_tag cli_mode workflow; do
		# Skip comments and empty lines
		[[ $vid =~ ^#.*$ ]] || [[ -z $vid ]] && continue

		if [[ $vid == "$variant_id" ]]; then
			export VARIANT_ID="$vid"
			export VARIANT_NAME="$name"
			export PATCHES_REPO="$patches_repo"
			export PATCHES_OWNER="$patches_owner"
			export PATCHES_TAG="$patches_tag"
			export CLI_REPO="$cli_repo"
			export CLI_OWNER="$cli_owner"
			export CLI_TAG="$cli_tag"
			export CLI_MODE="$cli_mode"
			export WORKFLOW_NAME="$workflow"
			green_log "[+] Loaded variant: $VARIANT_NAME"
			return 0
		fi
	done <"$VARIANTS_CONF"

	red_log "[-] Unknown variant: $variant_id"
	red_log "[-] Available variants:"
	grep -v '^#' "$VARIANTS_CONF" | grep -v '^$' | cut -d'|' -f1
	exit 1
}

# Get app configuration from apps.conf
# Returns: package_name|display_name|patch_key|architectures|options|dpi|extra_notes
get_app_config() {
	local app_name="$1"
	local config_line

	if [[ ! -f $APPS_CONF ]]; then
		red_log "[-] Apps configuration file not found: $APPS_CONF"
		exit 1
	fi

	# Find to app configuration line(s) matching to display_name
	config_line=$(grep -v '^#' "$APPS_CONF" | grep -v '^$' | grep -E "^\S+\|$app_name\|" | head -n1)

	if [[ -z $config_line ]]; then
		red_log "[-] Unknown app: $app_name"
		red_log "[-] Available apps:"
		grep -v '^#' "$APPS_CONF" | grep -v '^$' | cut -d'|' -f2 | sort -u
		exit 1
	fi

	echo "$config_line"
}

# Resolve variant-specific patch key with fallback
# Usage: resolve_patch_key <base_key> <variant_id>
# Returns: variant-specific patch key if exists, otherwise base_key
resolve_patch_key() {
	local base_key="$1"
	local variant="$2"
	local patches_dir
	patches_dir="$(dirname "$0")/../patches"

	if [[ -d "${patches_dir}/${base_key}-${variant}" ]]; then
		echo "${base_key}-${variant}"
		return 0
	fi

	if [[ $variant == *"android5"* ]]; then
		if [[ -d "${patches_dir}/${base_key}-android5" ]]; then
			echo "${base_key}-android5"
			return 0
		fi
		if [[ -d "${patches_dir}/${base_key}-5" ]]; then
			echo "${base_key}-5"
			return 0
		fi
		if [[ -d "${patches_dir}/${base_key}-extended-5" ]]; then
			echo "${base_key}-extended-5"
			return 0
		fi
	fi

	if [[ $variant == *"android67"* ]]; then
		if [[ -d "${patches_dir}/${base_key}-android6-7" ]]; then
			echo "${base_key}-android6-7"
			return 0
		fi
		if [[ -d "${patches_dir}/${base_key}-6-7" ]]; then
			echo "${base_key}-6-7"
			return 0
		fi
		if [[ -d "${patches_dir}/${base_key}-extended-6-7" ]]; then
			echo "${base_key}-extended-6-7"
			return 0
		fi
	fi

	if [[ $variant == *"anddea"* ]]; then
		if [[ -d "${patches_dir}/${base_key}-anddea" ]]; then
			echo "${base_key}-anddea"
			return 0
		fi
		if [[ $base_key == *"-revanced" ]] && [[ -d "${patches_dir}/${base_key%-revanced}-anddea" ]]; then
			echo "${base_key%-revanced}-anddea"
			return 0
		fi
	fi

	if [[ $variant == *"morphe"* ]]; then
		if [[ -d "${patches_dir}/${base_key}-morphe" ]]; then
			echo "${base_key}-morphe"
			return 0
		fi
		if [[ $base_key == *"-revanced" ]] && [[ -d "${patches_dir}/${base_key%-revanced}-morphe" ]]; then
			echo "${base_key%-revanced}-morphe"
			return 0
		fi
	fi

	if [[ $variant == *"extended"* ]]; then
		if [[ -d "${patches_dir}/${base_key}-extended" ]]; then
			echo "${base_key}-extended"
			return 0
		fi
		if [[ -d "${patches_dir}/${base_key}-extended-arsclib" ]]; then
			echo "${base_key}-extended-arsclib"
			return 0
		fi
		if [[ $base_key == *"revanced-extended"* ]]; then
			if [[ $variant == *"arsclib"* ]] && [[ -d "${patches_dir}/${base_key}-arsclib" ]]; then
				echo "${base_key}-arsclib"
				return 0
			fi
		fi
	fi

	if [[ $variant == *"arsclib"* ]]; then
		if [[ -d "${patches_dir}/${base_key}-arsclib" ]]; then
			echo "${base_key}-arsclib"
			return 0
		fi
		if [[ -d "${patches_dir}/${base_key}-rve-arsclib" ]]; then
			echo "${base_key}-rve-arsclib"
			return 0
		fi
	fi

	echo "$base_key"
	return 0
}

# Download variant-specific requirements (patches + CLI)
download_variant_requirements() {
	green_log "[+] Downloading requirements for $VARIANT_NAME"
	green_log "[+]   Patches: $PATCHES_OWNER/$PATCHES_REPO ($PATCHES_TAG)"
	green_log "[+]   CLI: $CLI_OWNER/$CLI_REPO ($CLI_TAG)"

	dl_gh "$PATCHES_REPO" "$PATCHES_OWNER" "$PATCHES_TAG"
	dl_gh "$CLI_REPO" "$CLI_OWNER" "$CLI_TAG"
}

# Determine output suffix based on variant
get_variant_suffix() {
	case "$VARIANT_ID" in
	*-beta)
		echo "-beta"
		;;
	*)
		echo ""
		;;
	esac
}

#################################################
# App Build Function
#################################################

# Build an app based on configuration
# Args: $1 = app_name (from apps.conf)
build_app() {
	local app_name="$1"
	local suffix
	local config
	local package_name
	local display_name
	local patch_key
	local architectures

	suffix=$(get_variant_suffix)

	# Get app configuration
	config=$(get_app_config "$app_name")
	# shellcheck disable=SC2034  # Some config fields (options, dpi, extra_notes) used elsewhere or for documentation
	IFS='|' read -r package_name display_name patch_key architectures options dpi extra_notes <<<"$config"

	# Resolve variant-specific patch key
	patch_key=$(resolve_patch_key "$patch_key" "$VARIANT_ID")

	green_log "[+] Building $display_name ($package_name)"
	green_log "[+]   Patch key: $patch_key"
	green_log "[+]   Architectures: $architectures"

	# Handle lite prefix in package_name (extract real package name for download)
	local download_pkg="$package_name"
	if [[ $package_name == lite:* ]]; then
		download_pkg="${package_name#*:}"
	fi

	# Download APK using unified download_apk function
	# Version handling:
	#   - Auto-detects version from CLI patches by default
	#   - Set lock_version=1 to download latest version from APKPure
	#   - Can pass specific version as 4th param if needed
	#
	# Architecture handling:
	#   - Single architecture: Pass as-is (arm64-v8a)
	#   - Multiple architectures: Pass semicolon-separated (arm64-v8a;armeabi-v7a;x86;x86_64)
	#   - Universal/lite: Pass empty string
	#
	local download_arch
	case "$architectures" in
	lite)
		download_arch="" # Let download_apk handle default
		;;
	all)
		download_arch="" # Universal APK
		;;
	*all*)
		# Universal + specific architecture (e.g., "arm64-v8a all")
		download_arch="" # Download universal, then extract specific arch
		;;
	arm64-v8a | armeabi-v7a | x86 | x86_64)
		# Single architecture - pass as-is
		download_arch="$architectures"
		;;
	*)
		# Multiple architectures - join with commas
		# Example: "arm64-v8a armeabi-v7a x86 x86_64" → "arm64-v8a,armeabi-v7a,x86,x86_64"
		download_arch="${architectures// /,}" # Replace spaces with commas
		;;
	esac

	# Download APK (auto-detect version unless lock_version=1)
	download_apk "$download_pkg" "${display_name}${suffix}" "$download_arch" || exit 1

	# Handle special architecture cases
	if [[ $architectures == "lite" ]]; then
		# Lite build with minimal language/DPI
		process_lite_builds "${display_name}${suffix}" "$VARIANT_ID" "$patch_key" "$CLI_MODE"
	elif [[ $architectures == "all" ]]; then
		# Universal APK for all architectures
		get_patches_key "$patch_key"
		patch "${display_name}${suffix}" "$VARIANT_ID" "$CLI_MODE"
	elif [[ $architectures == *" all"* ]]; then
		# Universal + specific architecture builds (e.g., "arm64-v8a all")
		local specific_arch="${architectures// all/}"
		# First build universal APK
		green_log "[+] Building universal APK"
		get_patches_key "$patch_key"
		patch "${display_name}${suffix}" "$VARIANT_ID" "$CLI_MODE"
		# Then build specific architecture APK
		green_log "[+] Building ${specific_arch} APK"
		process_architectures "${display_name}${suffix}" "$VARIANT_ID" "$patch_key" "$CLI_MODE" "$specific_arch"
	elif [[ -n $architectures ]]; then
		# Multiple architecture-specific builds
		process_architectures "${display_name}${suffix}" "$VARIANT_ID" "$patch_key" "$CLI_MODE" "$architectures"
	else
		# Single APK, no architecture splitting
		get_patches_key "$patch_key"
		patch "${display_name}${suffix}" "$VARIANT_ID" "$CLI_MODE"
	fi

	green_log "[+] ✓ Successfully built $display_name"
}

#################################################
# Main Entry Point
#################################################

# Usage check
if [[ $# -lt 2 ]]; then
	echo "Usage: $0 <variant> <app_name>"
	echo ""
	echo "Variants:"
	grep -v '^#' "$VARIANTS_CONF" | grep -v '^$' | awk -F'|' '{printf "  %-30s %s\n", $1, $2}'
	echo ""
	echo "Apps:"
	grep -v '^#' "$APPS_CONF" | grep -v '^$' | awk -F'|' '{printf "  %-30s %s\n", $2, $9}' | sort -u
	exit 1
fi

VARIANT="$1"
APP_NAME="$2"

# Parse variant configuration
parse_variant_config "$VARIANT"

# Download patches and CLI for this variant
download_variant_requirements

# Build the app
build_app "$APP_NAME"

green_log "[+] Build complete!"
