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

set -u # Error on unset variables
set -o pipefail # Exit if any part of a pipeline fails

# --- Binary I/O Helper Functions using dd and od ---

# read_u32_be(file, offset)
# Reads 4 bytes at $offset from $file as a Big Endian unsigned integer
read_u32_be() {
    local file="$1"
    local offset="$2"
    local hex
    hex=$(dd if="$file" bs=1 skip="$offset" count=4 2>/dev/null | od -t x1 -An | tr -d ' \n')
    if [ -z "$hex" ]; then
        echo "Error: Read failed at offset $offset" >&2
        return 1
    fi
    # Use 16# for hex conversion
    echo $((16#$hex))
}

# read_u16_be(file, offset)
# Reads 2 bytes at $offset from $file as a Big Endian unsigned integer
read_u16_be() {
    local file="$1"
    local offset="$2"
    local hex
    hex=$(dd if="$file" bs=1 skip="$offset" count=2 2>/dev/null | od -t x1 -An | tr -d ' \n')
    if [ -z "$hex" ]; then
        echo "Error: Read failed at offset $offset" >&2
        return 1
    fi
    echo $((16#$hex))
}

# read_u8(file, offset)
# Reads 1 byte at $offset from $file
read_u8() {
    local file="$1"
    local offset="$2"
    local hex
    hex=$(dd if="$file" bs=1 skip="$offset" count=1 2>/dev/null | od -t x1 -An | tr -d ' \n')
    if [ -z "$hex" ]; then
        echo "Error: Read failed at offset $offset" >&2
        return 1
    fi
    echo $((16#$hex))
}

# read_type(file, offset)
# Reads 4 bytes at $offset from $file as an ASCII string
read_type() {
    local file="$1"
    local offset="$2"
    dd if="$file" bs=1 skip="$offset" count=4 2>/dev/null
}

# decode_mp4_language(packed_lang_code)
# Decodes the 16-bit packed ISO-639-2/T language code from mdhd
decode_mp4_language() {
    local packed=$1
    if [ "$packed" -eq 0 ]; then
        echo "und" # Undetermined
        return
    fi

    # Each char is 5 bits, packed + 0x60
    local c1=$(( (packed >> 10) & 0x1F ))
    local c2=$(( (packed >> 5) & 0x1F ))
    local c3=$(( packed & 0x1F ))

    printf "\\$(printf '%03o' $((c1 + 0x60)))\\$(printf '%03o' $((c2 + 0x60)))\\$(printf '%03o' $((c3 + 0x60)))"
}


# --- Generic Atom Iterator ---

# iterate_atoms(file, start_offset, end_offset, callback_func, context_arg1, ...)
#
# Iterates atoms from $start_offset to $end_offset.
# Calls $callback_func for each atom:
#   $callback_func <file> <atom_type> <atom_size> <payload_offset> <context_arg1> ...
#
# Returns 1 if the callback requested to stop, 0 otherwise.
iterate_atoms() {
    local file="$1"
    local start_offset="$2"
    local end_offset="$3"
    local callback="$4"
    shift 4 # The rest of the args are context for the callback

    local pos=$start_offset
    local stop=0

    while [ "$pos" -lt "$end_offset" ] && [ "$stop" -eq 0 ]; do
        local atom_size
        atom_size=$(read_u32_be "$file" "$pos")
        
        local atom_type
        atom_type=$(read_type "$file" $((pos + 4)))

        local payload_offset=$((pos + 8))

        if [ "$atom_size" -lt 8 ]; then
            echo "Warning: Encountered invalid atom size $atom_size at offset $pos. Attempting recovery..." >&2
            # Try to find next atom (basic recovery)
            pos=$((pos + 1))
            continue
        fi

        # Note: This does NOT handle 64-bit atoms (size=1) or 'zero' atoms (size=0)
        # which is a major limitation, but matches the simplified goal.
        
        # Run the callback. The callback's return value determines if we stop.
        # We must check the return code with 'if' to prevent 'set -eE'
        # from firing when the callback returns '1' to stop iteration.
        if ! "$callback" "$file" "$atom_type" "$atom_size" "$payload_offset" "$@" ; then
            stop=$?
        else
            stop=0
        fi
        
        # Move to the next atom
        pos=$((pos + atom_size))
    done

    return $stop
}

# --- 'list' command implementation ---

# Global arrays to store track info
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

    # Start iteration, looking for 'moov'
    iterate_atoms "$file" 0 "$file_size" "find_moov_callback" "$file"
    
    # Print the collected data as JSON
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
    
    return 0
}

find_moov_callback() {
    local file="$1"
    local atom_type="$2"
    local atom_size="$3"
    local payload_offset="$4"
    
    if [ "$atom_type" == "moov" ]; then
        # Found 'moov', dive into it, looking for 'trak'
        iterate_atoms "$file" "$payload_offset" $((payload_offset + atom_size - 8)) "find_trak_callback" "$file"
        return 1 # Stop iterating top-level atoms
    fi
    return 0 # Continue
}

find_trak_callback() {
    local file="$1"
    local atom_type="$2"
    local atom_size="$3"
    local payload_offset="$4"

    if [ "$atom_type" == "trak" ]; then
        # Found a 'trak' atom. Create a new entry for it.
        local idx=$G_TRACK_COUNT
        G_TRACK_IDS[$idx]=0
        G_TRACK_TYPES[$idx]="unknown"
        G_TRACK_LANGS[$idx]="und"
        G_TRACK_DEFAULTS[$idx]="false"
        G_TRACK_FORCEDS[$idx]="false"
        
        # Parse this 'trak' atom for its children ('tkhd', 'mdia')
        iterate_atoms "$file" "$payload_offset" $((payload_offset + atom_size - 8)) "parse_trak_callback" "$file" "$idx"
        
        G_TRACK_COUNT=$((G_TRACK_COUNT + 1))
    fi
    return 0 # Continue searching for more 'trak' atoms
}

parse_trak_callback() {
    local file="$1"
    local atom_type="$2"
    local atom_size="$3"
    local payload_offset="$4"
    local idx="$6" # The index of the track we're populating (was $5)

    if [ "$atom_type" == "tkhd" ]; then
        parse_tkhd "$file" "$payload_offset" "$idx"
    elif [ "$atom_type" == "mdia" ]; then
        # Dive into 'mdia'
        iterate_atoms "$file" "$payload_offset" $((payload_offset + atom_size - 8)) "parse_mdia_callback" "$file" "$idx"
    fi
    return 0 # Continue parsing this 'trak'
}

parse_tkhd() {
    local file="$1"
    local payload_offset="$2"
    local idx="$3"
    
    # [0]   : version
    # [1-3] : flags
    local version
    version=$(read_u8 "$file" "$payload_offset")
    
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
    
    G_TRACK_IDS[$idx]=$(read_u32_be "$file" "$track_id_offset")
    return 0
}

parse_mdia_callback() {
    local file="$1"
    local atom_type="$2"
    local atom_size="$3"
    local payload_offset="$4"
    local idx="$6" # (was $5)

    if [ "$atom_type" == "mdhd" ]; then
        parse_mdhd "$file" "$payload_offset" "$idx"
    elif [ "$atom_type" == "hdlr" ]; then
        parse_hdlr "$file" "$payload_offset" "$idx"
    elif [ "$atom_type" == "minf" ]; then
        # Dive into 'minf'
        iterate_atoms "$file" "$payload_offset" $((payload_offset + atom_size - 8)) "parse_minf_callback" "$file" "$idx"
    fi
    return 0 # Continue parsing 'mdia'
}

parse_mdhd() {
    local file="$1"
    local payload_offset="$2"
    local idx="$3"
    
    local version
    version=$(read_u8 "$file" "$payload_offset")
    
    local lang_offset
    if [ "$version" -eq 1 ]; then
        lang_offset=$((payload_offset + 28)) # version(1) + flags(3) + ctime(8) + mtime(8) + timescale(4) + duration(8)
    else
        lang_offset=$((payload_offset + 20)) # version(1) + flags(3) + ctime(4) + mtime(4) + timescale(4) + duration(4)
    fi
    
    local lang_packed
    lang_packed=$(read_u16_be "$file" "$lang_offset")
    
    G_TRACK_LANGS[$idx]=$(decode_mp4_language "$lang_packed")
    return 0
}

parse_hdlr() {
    local file="$1"
    local payload_offset="$2"
    local idx="$3"
    
    # [8-11] : handler type
    local handler_type_offset=$((payload_offset + 8))
    local type
    type=$(read_type "$file" "$handler_type_offset")
    
    case "$type" in
        "vide") G_TRACK_TYPES[$idx]="video" ;;
        "soun") G_TRACK_TYPES[$idx]="audio" ;;
        "subt"|"sbtl"|"text") G_TRACK_TYPES[$idx]="subtitle" ;;
        *) G_TRACK_TYPES[$idx]="$type" ;;
    esac
    return 0
}

parse_minf_callback() {
    local file="$1"
    local atom_type="$2"
    local atom_size="$3"
    local payload_offset="$4"
    local idx="$6" # (was $5)

    if [ "$atom_type" == "stbl" ]; then
        # Dive into 'stbl'
        iterate_atoms "$file" "$payload_offset" $((payload_offset + atom_size - 8)) "parse_stbl_callback" "$file" "$idx"
    fi
    return 0 # Continue parsing 'minf'
}

parse_stbl_callback() {
    local file="$1"
    local atom_type="$2"
    local atom_size="$3"
    local payload_offset="$4"
    local idx="$6" # (was $5)

    if [ "$atom_type" == "stsd" ]; then
        parse_stsd "$file" "$payload_offset" "$idx"
    fi
    return 0 # Continue parsing 'stbl'
}

parse_stsd() {
    local file="$1"
    local payload_offset="$2"
    local idx="$3"
    
    # [4-7] : entry_count (stsd has version/flags, then entry_count)
    local entry_count
    entry_count=$(read_u32_be "$file" "$((payload_offset + 4))")
    
    if [ "$entry_count" -gt 0 ]; then
        # Just check the first sample entry
        # [8-11]  : sample_description_size
        # [12-15] : sample_description_type (e.g., 'tx3g', 'mp4a')
        local sample_type
        sample_type=$(read_type "$file" "$((payload_offset + 12))")
        
        # This matches the non-standard Java logic
        if [[ "$sample_type" == *"fcd "* ]]; then
            G_TRACK_FORCEDS[$idx]="true"
        else
            G_TRACK_FORCEDS[$idx]="false"
        fi
    fi
    return 0
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
    
    local found=0
    
    if [ "$atom_type" == "moov" ] || [ "$atom_type" == "trak" ]; then
        # Recurse into container atoms
        iterate_atoms "$file" "$payload_offset" $((payload_offset + atom_size - 8)) \
            "find_and_patch_tkhd_callback" "$target_track_id" "$command"
        found=$?
    elif [ "$atom_type" == "tkhd" ]; then
        # Process this 'tkhd' atom
        found=$(check_and_patch_tkhd "$file" "$payload_offset" "$target_track_id" "$command")
    fi
    
    return $found # Propagate 'found' status up
}

# check_and_patch_tkhd(file, tkhd_payload_offset, target_track_id, command)
#
# This function checks a 'tkhd' atom's track ID and patches its flags
# if it matches the target.
# Returns 1 if patched, 0 otherwise.
check_and_patch_tkhd() {
    local file="$1"
    local payload_offset="$2"
    local target_track_id="$3"
    local command="$4"
    local found=0

    # Per the Java code/MP4 spec:
    # tkhd payload:
    # [0]       : version (1 byte)
    # [1-3]     : flags (3 bytes)
    # [12-15]   : track_id (if version 0)
    # [20-23]   : track_id (if version 1)

    local version
    version=$(read_u8 "$file" "$payload_offset")

    local track_id_offset
    local flags_offset=$((payload_offset + 1))

    if [ "$version" -eq 1 ]; then
        track_id_offset=$((payload_offset + 20))
    else
        track_id_offset=$((payload_offset + 12))
    fi

    local track_id
    track_id=$(read_u32_be "$file" "$track_id_offset")

    if [ "$track_id" -eq "$target_track_id" ]; then
        echo "Found track $track_id at offset $payload_offset" >&2

        # Read the 3 flag bytes
        local flags_hex
        flags_hex=$(dd if="$file" bs=1 skip="$flags_offset" count=3 2>/dev/null | od -t x1 -An | tr -d ' \n')
        local flags_dec=$((16#$flags_hex))

        local new_flags_dec
        if [ "$command" == "set" ]; then
            # Set the last bit ('default' flag)
            new_flags_dec=$((flags_dec | 1))
            echo "Setting 'default' flag..." >&2
        else # "unset"
            # Unset the last bit
            new_flags_dec=$((flags_dec & 0xFFFFFE)) # 0xFFFFFE is ...11111110
            echo "Unsetting 'default' flag..." >&2
        fi

        if [ "$flags_dec" -eq "$new_flags_dec" ]; then
            echo "Flag is already in the desired state." >&2
            found=1
        else
            # Convert decimal back to 3 hex bytes
            local new_flags_hex
            new_flags_hex=$(printf '%06x' $new_flags_dec)

            # Extract 3 bytes from hex string
            local b1=$((16#${new_flags_hex:0:2}))
            local b2=$((16#${new_flags_hex:2:2}))
            local b3=$((16#${new_flags_hex:4:2}))

            # Write the bytes back using printf and dd
            # We must use conv=notrunc to avoid truncating the file
            printf "\\$(printf '%03o' $b1)\\$(printf '%03o' $b2)\\$(printf '%03o' $b3)" | \
                dd of="$file" bs=1 seek="$flags_offset" count=3 conv=notrunc 2>/dev/null

            if [ $? -eq 0 ]; then
                echo "Successfully patched track $track_id." >&2
                found=1
            else
                echo "Error: Failed to write to file at offset $flags_offset" >&2
                # We'll still return 1 to stop, set -e will halt on error
                found=1
            fi
        fi
    fi

    # Return "found" status
    echo "$found"
}


# --- Main Script ---

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

# --- Argument Validation ---
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

# --- Execution ---

FILE_SIZE=$(stat -c%s "$FILE")
if [ "$FILE_SIZE" -lt 64 ]; then
    echo "Error: File is too small to be a valid MP4." >&2
    exit 1
fi

if [ "$CMD" == "list" ]; then
    echo "Scanning '$FILE' (Size: $FILE_SIZE bytes)..." >&2
    list_tracks "$FILE" "$FILE_SIZE"

elif [ "$CMD" == "set" ] || [ "$CMD" == "unset" ]; then
    echo "WARNING: This script will directly modify '$FILE'."
    echo "Please ensure you have a backup."
    read -p "Continue? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Operation cancelled."
        exit 1
    fi
    
    echo "Scanning '$FILE' (Size: $FILE_SIZE bytes)..." >&2
    
    # Start scanning from the beginning of the file (offset 0)
    iterate_atoms "$FILE" 0 "$FILE_SIZE" "find_and_patch_tkhd_callback" "$TRACK_ID" "$CMD"
    FINAL_STATUS=$?

    if [ "$FINAL_STATUS" -eq 1 ]; then
        echo "Operation completed successfully." >&2
    else
        echo "Could not find track ID $TRACK_ID in the file." >&2
        exit 1
    fi
fi
