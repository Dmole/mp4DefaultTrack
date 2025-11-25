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

# Global registers for return values to avoid subshells and capture errors
G_RET_VAL=0
G_RET_STR=""
G_STOP_ITER=0

# read_u32_be(file, offset)
# Reads 4 bytes at $offset from $file as a Big Endian unsigned integer
# Sets G_RET_VAL
read_u32_be() {
    local file="$1"
    local offset="$2"
    local hex
    hex=$(dd if="$file" bs=1 skip="$offset" count=4 2>/dev/null | od -t x1 -An | tr -d ' \n')
    if [ -z "$hex" ]; then
        echo "Error: Read failed at offset $offset" >&2
        return 1
    fi
    G_RET_VAL=$((16#$hex))
}

# read_u16_be(file, offset)
# Reads 2 bytes at $offset from $file as a Big Endian unsigned integer
# Sets G_RET_VAL
read_u16_be() {
    local file="$1"
    local offset="$2"
    local hex
    hex=$(dd if="$file" bs=1 skip="$offset" count=2 2>/dev/null | od -t x1 -An | tr -d ' \n')
    if [ -z "$hex" ]; then
        echo "Error: Read failed at offset $offset" >&2
        return 1
    fi
    G_RET_VAL=$((16#$hex))
}

# read_u8(file, offset)
# Reads 1 byte at $offset from $file
# Sets G_RET_VAL
read_u8() {
    local file="$1"
    local offset="$2"
    local hex
    hex=$(dd if="$file" bs=1 skip="$offset" count=1 2>/dev/null | od -t x1 -An | tr -d ' \n')
    if [ -z "$hex" ]; then
        echo "Error: Read failed at offset $offset" >&2
        return 1
    fi
    G_RET_VAL=$((16#$hex))
}

# read_type(file, offset)
# Reads 4 bytes at $offset from $file as an ASCII string
# Sets G_RET_STR
read_type() {
    local file="$1"
    local offset="$2"
    G_RET_STR=$(dd if="$file" bs=1 skip="$offset" count=4 2>/dev/null)
}

# decode_mp4_language(packed_lang_code)
# Decodes the 16-bit packed ISO-639-2/T language code from mdhd
# Sets G_RET_STR
decode_mp4_language() {
    local packed=$1
    if [ "$packed" -eq 0 ]; then
        G_RET_STR="und"
        return
    fi
    local c1=$(( (packed >> 10) & 0x1F ))
    local c2=$(( (packed >> 5) & 0x1F ))
    local c3=$(( packed & 0x1F ))
    G_RET_STR=$(printf "\\$(printf '%03o' $((c1 + 0x60)))\\$(printf '%03o' $((c2 + 0x60)))\\$(printf '%03o' $((c3 + 0x60)))")
}


# --- Generic Atom Iterator ---

# iterate_atoms(file, start_offset, end_offset, callback_func, context_arg1, ...)
#
# Iterates atoms from $start_offset to $end_offset.
# Calls $callback_func for each atom:
#   $callback_func <file> <atom_type> <atom_size> <payload_offset> <context_arg1> ...
#
# Checks global G_STOP_ITER to determine if loop should break.
iterate_atoms() {
    local file="$1"
    local start_offset="$2"
    local end_offset="$3"
    local callback="$4"
    shift 4

    local pos=$start_offset
    # Note: G_STOP_ITER is NOT reset here to allow recursive stops to propagate up

    while [ "$pos" -lt "$end_offset" ] && [ "${G_STOP_ITER:-0}" -eq 0 ]; do
        read_u32_be "$file" "$pos"
        local atom_size=$G_RET_VAL

        read_type "$file" $((pos + 4))
        local atom_type="$G_RET_STR"

        local payload_offset=$((pos + 8))

        if [ "$atom_size" -lt 8 ]; then
            echo "Warning: Encountered invalid atom size $atom_size at offset $pos. Attempting recovery..." >&2
            # Try to find next atom (basic recovery)
            pos=$((pos + 1))
            continue
        fi

        # Execute callback directly (no 'if', no '$()')
        "$callback" "$file" "$atom_type" "$atom_size" "$payload_offset" "$@"

        # Check global stop flag
        if [ "${G_STOP_ITER:-0}" -eq 1 ]; then
            break
        fi

        pos=$((pos + atom_size))
    done
}

declare -a G_TRACK_IDS
declare -a G_TRACK_TYPES
declare -a G_TRACK_LANGS
declare -a G_TRACK_DEFAULTS
declare -a G_TRACK_FORCEDS
declare -i G_TRACK_COUNT=0

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
    local file="$1"
    local atom_type="$2"
    local atom_size="$3"
    local payload_offset="$4"

    if [ "$atom_type" == "moov" ]; then
        iterate_atoms "$file" "$payload_offset" $((payload_offset + atom_size - 8)) "find_trak_callback" "$file"
        # Found moov, stop top-level iteration
        G_STOP_ITER=1
    fi
}

find_trak_callback() {
    local file="$1"
    local atom_type="$2"
    local atom_size="$3"
    local payload_offset="$4"

    if [ "$atom_type" == "trak" ]; then
        local idx=$G_TRACK_COUNT
        G_TRACK_IDS[$idx]=0
        G_TRACK_TYPES[$idx]="unknown"
        G_TRACK_LANGS[$idx]="und"
        G_TRACK_DEFAULTS[$idx]="false"
        G_TRACK_FORCEDS[$idx]="false"

        iterate_atoms "$file" "$payload_offset" $((payload_offset + atom_size - 8)) "parse_trak_callback" "$file" "$idx"

        G_TRACK_COUNT=$((G_TRACK_COUNT + 1))
    fi
}

parse_trak_callback() {
    local file="$1"
    local atom_type="$2"
    local atom_size="$3"
    local payload_offset="$4"
    local idx="$6"

    if [ "$atom_type" == "tkhd" ]; then
        parse_tkhd "$file" "$payload_offset" "$idx"
    elif [ "$atom_type" == "mdia" ]; then
        iterate_atoms "$file" "$payload_offset" $((payload_offset + atom_size - 8)) "parse_mdia_callback" "$file" "$idx"
    fi
}

parse_tkhd() {
    local file="$1"
    local payload_offset="$2"
    local idx="$3"

    read_u8 "$file" "$payload_offset"
    local version=$G_RET_VAL

    local flags_hex
    flags_hex=$(dd if="$file" bs=1 skip="$((payload_offset + 1))" count=3 2>/dev/null | od -t x1 -An | tr -d ' \n')
    local flags_dec=$((16#$flags_hex))

    if [ $((flags_dec & 1)) -ne 0 ]; then
        G_TRACK_DEFAULTS[$idx]="true"
    else
        G_TRACK_DEFAULTS[$idx]="false"
    fi

    local track_id_offset
    if [ "$version" -eq 1 ]; then
        track_id_offset=$((payload_offset + 20))
    else
        track_id_offset=$((payload_offset + 12))
    fi

    read_u32_be "$file" "$track_id_offset"
    G_TRACK_IDS[$idx]=$G_RET_VAL
}

parse_mdia_callback() {
    local file="$1"
    local atom_type="$2"
    local atom_size="$3"
    local payload_offset="$4"
    local idx="$6"

    if [ "$atom_type" == "mdhd" ]; then
        parse_mdhd "$file" "$payload_offset" "$idx"
    elif [ "$atom_type" == "hdlr" ]; then
        parse_hdlr "$file" "$payload_offset" "$idx"
    elif [ "$atom_type" == "minf" ]; then
        iterate_atoms "$file" "$payload_offset" $((payload_offset + atom_size - 8)) "parse_minf_callback" "$file" "$idx"
    fi
}

parse_mdhd() {
    local file="$1"
    local payload_offset="$2"
    local idx="$3"

    read_u8 "$file" "$payload_offset"
    local version=$G_RET_VAL

    local lang_offset
    if [ "$version" -eq 1 ]; then
        lang_offset=$((payload_offset + 28))
    else
        lang_offset=$((payload_offset + 20))
    fi

    read_u16_be "$file" "$lang_offset"
    decode_mp4_language "$G_RET_VAL"
    G_TRACK_LANGS[$idx]="$G_RET_STR"
}

parse_hdlr() {
    local file="$1"
    local payload_offset="$2"
    local idx="$3"

    local handler_type_offset=$((payload_offset + 8))
    read_type "$file" "$handler_type_offset"
    local type="$G_RET_STR"

    case "$type" in
        "vide") G_TRACK_TYPES[$idx]="video" ;;
        "soun") G_TRACK_TYPES[$idx]="audio" ;;
        "subt"|"sbtl"|"text") G_TRACK_TYPES[$idx]="subtitle" ;;
        *) G_TRACK_TYPES[$idx]="$type" ;;
    esac
}

parse_minf_callback() {
    local file="$1"
    local atom_type="$2"
    local atom_size="$3"
    local payload_offset="$4"
    local idx="$6"

    if [ "$atom_type" == "stbl" ]; then
        iterate_atoms "$file" "$payload_offset" $((payload_offset + atom_size - 8)) "parse_stbl_callback" "$file" "$idx"
    fi
}

parse_stbl_callback() {
    local file="$1"
    local atom_type="$2"
    local atom_size="$3"
    local payload_offset="$4"
    local idx="$6"

    if [ "$atom_type" == "stsd" ]; then
        parse_stsd "$file" "$payload_offset" "$idx"
    fi
}

parse_stsd() {
    local file="$1"
    local payload_offset="$2"
    local idx="$3"

    read_u32_be "$file" "$((payload_offset + 4))"
    local entry_count=$G_RET_VAL

    if [ "$entry_count" -gt 0 ]; then
        read_type "$file" "$((payload_offset + 12))"
        local sample_type="$G_RET_STR"

        if [[ "$sample_type" == *"fcd "* ]]; then
            G_TRACK_FORCEDS[$idx]="true"
        else
            G_TRACK_FORCEDS[$idx]="false"
        fi
    fi
}


# --- 'set'/'unset' command implementation ---

# This callback finds the 'tkhd' atom for the *target* track ID
# and patches it.
find_and_patch_tkhd_callback() {
    local file="$1"
    local atom_type="$2"
    local atom_size="$3"
    local payload_offset="$4"
    local target_track_id="$5"
    local command="$6"

    if [ "$atom_type" == "moov" ] || [ "$atom_type" == "trak" ]; then
        iterate_atoms "$file" "$payload_offset" $((payload_offset + atom_size - 8)) \
            "find_and_patch_tkhd_callback" "$target_track_id" "$command"

    elif [ "$atom_type" == "tkhd" ]; then
        check_and_patch_tkhd "$file" "$payload_offset" "$target_track_id" "$command"
    fi
}

# check_and_patch_tkhd(file, tkhd_payload_offset, target_track_id, command)
#
# This function checks a 'tkhd' atom's track ID and patches its flags
# if it matches the target.
# Sets G_STOP_ITER=1 if patched.
check_and_patch_tkhd() {
    local file="$1"
    local payload_offset="$2"
    local target_track_id="$3"
    local command="$4"

    read_u8 "$file" "$payload_offset"
    local version=$G_RET_VAL

    local track_id_offset
    local flags_offset=$((payload_offset + 1))

    if [ "$version" -eq 1 ]; then
        track_id_offset=$((payload_offset + 20))
    else
        track_id_offset=$((payload_offset + 12))
    fi

    read_u32_be "$file" "$track_id_offset"
    local track_id=$G_RET_VAL

    if [ "$track_id" -eq "$target_track_id" ]; then
        local flags_hex
        flags_hex=$(dd if="$file" bs=1 skip="$flags_offset" count=3 2>/dev/null | od -t x1 -An | tr -d ' \n')
        local flags_dec=$((16#$flags_hex))

        local new_flags_dec
        if [ "$command" == "set" ]; then
            new_flags_dec=$((flags_dec | 1))
        else
            new_flags_dec=$((flags_dec & 0xFFFFFE))
        fi

        if [ "$flags_dec" -ne "$new_flags_dec" ]; then
            local new_flags_hex
            new_flags_hex=$(printf '%06x' $new_flags_dec)

            local b1=$((16#${new_flags_hex:0:2}))
            local b2=$((16#${new_flags_hex:2:2}))
            local b3=$((16#${new_flags_hex:4:2}))

            printf "\\$(printf '%03o' $b1)\\$(printf '%03o' $b2)\\$(printf '%03o' $b3)" | \
                dd of="$file" bs=1 seek="$flags_offset" count=3 conv=notrunc 2>/dev/null
        fi

        # Found target track, stop everything
        G_STOP_ITER=1
    fi
}

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <list|set|unset> <file> [trackId]" >&2
    echo "  list <file>              : List all tracks and their flags." >&2
    echo "  set <file> <trackId>     : Set 'default' flag for trackId." >&2
    echo "  unset <file> <trackId>   : Unset 'default' flag for trackId." >&2
    echo "  Note: 'forced' flag manipulation is not implemented." >&2
    exit 1
fi

CMD="$1"
FILE="$2"

if [ "$CMD" != "list" ] && [ "$CMD" != "set" ] && [ "$CMD" != "unset" ]; then
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
    if ! [[ "$TRACK_ID" =~ ^[0-9]+$ ]]; then
        echo "Error: trackId must be a number." >&2
        exit 1
    fi
    if ! [ -w "$FILE" ]; then
        echo "Error: File is not writable: $FILE" >&2
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
