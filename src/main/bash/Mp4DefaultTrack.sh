#!/bin/bash

set -eE
log_func() {
	local I="${#FUNCNAME[@]}"
	local I; I="$((I-2))"
	if [ "$I" -gt "0" ] ; then
		echo -n " # "
	fi
	while [ "$I" -ge "1" ]; do
		echo -n "${FUNCNAME[$I]} > "
		((I--))
	done
}
finalize() {
	sleep 0
}
WAS_ERR=false
trap 'echo "ERROR: $BASH_SOURCE:$LINENO $BASH_COMMAND$(log_func)" >&2;WAS_ERR=true' ERR
trap 'R=$?; finalize; if [ "$R" -ne 0 ] && ! $WAS_ERR ; then echo "EXIT: $BASH_SOURCE: $BASH_COMMAND$(log_func)" >&2; fi' EXIT

# Global registers
G_RET_STR=""
G_STOP_ITER=0

declare -a G_TRACK_IDS
declare -a G_TRACK_TYPES
declare -a G_TRACK_LANGS
declare -a G_TRACK_DEFAULTS
declare -a G_TRACK_FORCEDS
declare -i G_TRACK_COUNT=0

# decode_mp4_language(packed_lang_code)
# Decodes the 16-bit packed ISO-639-2/T language code from mdhd. Zero subshells.
decode_mp4_language() {
	local packed=$1
	if [ "$packed" -eq 0 ] || [ "$packed" -eq 32767 ]; then
		G_RET_STR="und"
		return
	fi
	local c1=$(( (packed >> 10) & 0x1F ))
	local c2=$(( (packed >> 5) & 0x1F ))
	local c3=$(( packed & 0x1F ))
	
	local o1 o2 o3
	printf -v o1 '%o' $((c1 + 0x60))
	printf -v o2 '%o' $((c2 + 0x60))
	printf -v o3 '%o' $((c3 + 0x60))
	printf -v G_RET_STR '%b' "\\0$o1\\0$o2\\0$o3"
}

# iterate_atoms(file, start_offset, end_offset, callback_func, context_arg1, ...)
iterate_atoms() {
	local file="$1"
	local start_offset="$2"
	local end_offset="$3"
	local callback="$4"
	shift 4

	local pos=$start_offset

	while [ "$pos" -lt "$end_offset" ] && [ "${G_STOP_ITER:-0}" -eq 0 ]; do
		# Read 8 bytes (Size + Type) via a single od process. Collapse hex using bash expansion.
		local hex
		printf -v hex '%s' $(od -A n -t x1 -j "$pos" -N 8 "$file")
		if [ -z "$hex" ] || [ "${#hex}" -lt 16 ]; then break; fi

		local atom_size=$((16#${hex:0:8}))
		local atom_type
		printf -v atom_type '%b' "\x${hex:8:2}\x${hex:10:2}\x${hex:12:2}\x${hex:14:2}"

		local payload_offset=$((pos + 8))

		if [ "$atom_size" -eq 1 ]; then
			# 64-bit extended size
			local hex_ext
			printf -v hex_ext '%s' $(od -A n -t x1 -j "$payload_offset" -N 8 "$file")
			atom_size=$((16#$hex_ext))
			payload_offset=$((pos + 16))
		elif [ "$atom_size" -eq 0 ]; then
			# size 0 extends to end of file
			atom_size=$((end_offset - pos))
		elif [ "$atom_size" -lt 8 ]; then
			echo "Warning: Invalid atom size $atom_size at $pos." >&2
			pos=$((pos + 1))
			continue
		fi

		"$callback" "$file" "$atom_type" "$atom_size" "$payload_offset" "$@"

		if [ "${G_STOP_ITER:-0}" -eq 1 ]; then
			break
		fi
		pos=$((pos + atom_size))
	done
}

list_tracks() {
	local file="$1"
	local file_size="$2"

	G_TRACK_IDS=()
	G_TRACK_TYPES=()
	G_TRACK_LANGS=()
	G_TRACK_DEFAULTS=()
	G_TRACK_FORCEDS=()
	G_TRACK_COUNT=0
	G_STOP_ITER=0

	iterate_atoms "$file" 0 "$file_size" "find_moov_callback" "$file"

	echo "["
	for (( i=0; i<$G_TRACK_COUNT; i++ )); do
		local id="${G_TRACK_IDS[$i]:-0}"
		local type="${G_TRACK_TYPES[$i]:-unknown}"
		local lang="${G_TRACK_LANGS[$i]:-und}"
		local def="${G_TRACK_DEFAULTS[$i]:-false}"
		local forced="${G_TRACK_FORCEDS[$i]:-false}"

		local comma=","
		if [ $i -eq $((G_TRACK_COUNT - 1)) ]; then
			comma=""
		fi

		printf "	{\"id\": %d, \"type\": \"%s\", \"lang\": \"%s\", \"default\": %s, \"forced\": %s}%s\n" \
			"$id" "$type" "$lang" "$def" "$forced" "$comma"
	done
	echo "]"
}

find_moov_callback() {
	if [ "$2" == "moov" ]; then
		iterate_atoms "$1" "$4" $(($4 + $3 - 8)) "find_trak_callback" "$1"
		G_STOP_ITER=1
	fi
}

find_trak_callback() {
	if [ "$2" == "trak" ]; then
		local idx=$G_TRACK_COUNT
		G_TRACK_IDS[$idx]=0
		G_TRACK_TYPES[$idx]="unknown"
		G_TRACK_LANGS[$idx]="und"
		G_TRACK_DEFAULTS[$idx]="false"
		G_TRACK_FORCEDS[$idx]="false"

		iterate_atoms "$1" "$4" $(($4 + $3 - 8)) "parse_trak_callback" "$1" "$idx"
		G_TRACK_COUNT=$((G_TRACK_COUNT + 1))
	fi
}

parse_trak_callback() {
	if [ "$2" == "tkhd" ]; then
		parse_tkhd "$1" "$4" "$6"
	elif [ "$2" == "mdia" ]; then
		iterate_atoms "$1" "$4" $(($4 + $3 - 8)) "parse_mdia_callback" "$1" "$6"
	fi
}

parse_tkhd() {
	local file="$1" payload_offset="$2" idx="$3"
	# Read 24 bytes at once to grab version, flags, and max distance to track_id
	local hex
	printf -v hex '%s' $(od -A n -t x1 -j "$payload_offset" -N 24 "$file")
	
	local version=$((16#${hex:0:2}))
	local flags_dec=$((16#${hex:2:6}))

	if [ $((flags_dec & 1)) -ne 0 ]; then
		G_TRACK_DEFAULTS[$idx]="true"
	else
		G_TRACK_DEFAULTS[$idx]="false"
	fi

	if [ "$version" -eq 1 ]; then
		G_TRACK_IDS[$idx]=$((16#${hex:40:8}))
	else
		G_TRACK_IDS[$idx]=$((16#${hex:24:8}))
	fi
}

parse_mdia_callback() {
	if [ "$2" == "mdhd" ]; then
		parse_mdhd "$1" "$4" "$6"
	elif [ "$2" == "hdlr" ]; then
		parse_hdlr "$1" "$4" "$6"
	elif [ "$2" == "minf" ]; then
		iterate_atoms "$1" "$4" $(($4 + $3 - 8)) "parse_minf_callback" "$1" "$6"
	fi
}

parse_mdhd() {
	local file="$1" payload_offset="$2" idx="$3"
	# Read up to 34 bytes to guarantee coverage of the language block
	local hex
	printf -v hex '%s' $(od -A n -t x1 -j "$payload_offset" -N 34 "$file")
	
	local version=$((16#${hex:0:2}))
	local lang_hex
	if [ "$version" -eq 1 ]; then
		lang_hex=${hex:64:4}
	else
		lang_hex=${hex:40:4}
	fi

	decode_mp4_language "$((16#$lang_hex))"
	G_TRACK_LANGS[$idx]="$G_RET_STR"
}

parse_hdlr() {
	local file="$1" payload_offset="$2" idx="$3"
	local hex type
	printf -v hex '%s' $(od -A n -t x1 -j "$((payload_offset + 8))" -N 4 "$file")
	printf -v type '%b' "\x${hex:0:2}\x${hex:2:2}\x${hex:4:2}\x${hex:6:2}"

	case "$type" in
		"vide") G_TRACK_TYPES[$idx]="video" ;;
		"soun") G_TRACK_TYPES[$idx]="audio" ;;
		"subt"|"sbtl"|"text") G_TRACK_TYPES[$idx]="subtitle" ;;
		*) G_TRACK_TYPES[$idx]="$type" ;;
	esac
}

parse_minf_callback() {
	if [ "$2" == "stbl" ]; then
		iterate_atoms "$1" "$4" $(($4 + $3 - 8)) "parse_stbl_callback" "$1" "$6"
	fi
}

parse_stbl_callback() {
	if [ "$2" == "stsd" ]; then
		parse_stsd "$1" "$4" "$6"
	fi
}

parse_stsd() {
	local file="$1" payload_offset="$2" idx="$3"
	local hex
	printf -v hex '%s' $(od -A n -t x1 -j "$payload_offset" -N 16 "$file")
	local entry_count=$((16#${hex:8:8}))

	if [ "$entry_count" -gt 0 ]; then
		local sample_type
		printf -v sample_type '%b' "\x${hex:24:2}\x${hex:26:2}\x${hex:28:2}\x${hex:30:2}"
		if [[ "$sample_type" == *"fcd "* ]]; then
			G_TRACK_FORCEDS[$idx]="true"
		else
			G_TRACK_FORCEDS[$idx]="false"
		fi
	fi
}

find_and_patch_tkhd_callback() {
	if [ "$2" == "moov" ] || [ "$2" == "trak" ]; then
		iterate_atoms "$1" "$4" $(($4 + $3 - 8)) "find_and_patch_tkhd_callback" "$5" "$6"
	elif [ "$2" == "tkhd" ]; then
		check_and_patch_tkhd "$1" "$4" "$5" "$6"
	fi
}

check_and_patch_tkhd() {
	local file="$1" payload_offset="$2" target_track_id="$3" command="$4"
	local hex
	printf -v hex '%s' $(od -A n -t x1 -j "$payload_offset" -N 24 "$file")

	local version=$((16#${hex:0:2}))
	local flags_dec=$((16#${hex:2:6}))
	local track_id
	
	if [ "$version" -eq 1 ]; then
		track_id=$((16#${hex:40:8}))
	else
		track_id=$((16#${hex:24:8}))
	fi

	if [ "$track_id" -eq "$target_track_id" ]; then
		local new_flags_dec
		if [ "$command" == "set" ]; then
			new_flags_dec=$((flags_dec | 1))
		else
			new_flags_dec=$((flags_dec & 0xFFFFFE))
		fi

		if [ "$flags_dec" -ne "$new_flags_dec" ]; then
			local new_flags_hex
			printf -v new_flags_hex '%06x' "$new_flags_dec"
			# Write changes in a single operation
			printf '%b' "\x${new_flags_hex:0:2}\x${new_flags_hex:2:2}\x${new_flags_hex:4:2}" | \
				dd of="$file" bs=1 seek="$((payload_offset + 1))" count=3 conv=notrunc 2>/dev/null
		fi
		G_STOP_ITER=1
	fi
}

if [ "$#" -lt 2 ]; then
	echo "Usage: $0 <list|set|unset> <file> [trackId]" >&2
	exit 1
fi

CMD="$1"
FILE="$2"

if [[ ! "$CMD" =~ ^(list|set|unset)$ ]]; then
	echo "Error: Command must be 'list', 'set', or 'unset'." >&2
	exit 1
fi
if ! [ -f "$FILE" ]; then
	echo "Error: File not found: $FILE" >&2
	exit 1
fi

TRACK_ID=""
if [ "$CMD" == "set" ] || [ "$CMD" == "unset" ]; then
	if [ "$#" -lt 3 ]; then
		echo "Error: Missing <trackId> for 'set'/'unset' command." >&2
		exit 1
	fi
	TRACK_ID="$3"
	if ! [[ "$TRACK_ID" =~ ^[0-9]+$ ]] || ! [ -w "$FILE" ]; then
		echo "Error: Invalid trackId or file is not writable." >&2
		exit 1
	fi
fi

FILE_SIZE=$(stat -c%s "$FILE")
if [ "$FILE_SIZE" -lt 64 ]; then
	echo "Error: File is too small to be a valid MP4." >&2
	exit 1
fi

if [ "$CMD" == "list" ]; then
	list_tracks "$FILE" "$FILE_SIZE"
elif [ "$CMD" == "set" ] || [ "$CMD" == "unset" ]; then
	G_STOP_ITER=0
	iterate_atoms "$FILE" 0 "$FILE_SIZE" "find_and_patch_tkhd_callback" "$TRACK_ID" "$CMD"
	if [ "$G_STOP_ITER" -eq 1 ]; then
		exit 0
	else
		echo "Could not find track ID $TRACK_ID in the file." >&2
		exit 1
	fi
fi
