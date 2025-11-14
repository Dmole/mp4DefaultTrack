#!/bin/bash

set -eE
WAS_ERR=false
trap 'echo "ERROR: $BASH_SOURCE:$LINENO $BASH_COMMAND" >&2;WAS_ERR=true' ERR
trap 'R=$?; if [ "$R" -ne 0 ] && ! $WAS_ERR ; then echo "EXIT: $BASH_SOURCE: $BASH_COMMAND" >&2; fi' EXIT

get() {
	CMD="$1"
	PKG="$2"
	if [ "$PKG" == "" ] ; then
		PKG="$CMD"
	fi
	# time is a shell keyword
	if ! type -a "$CMD" 2>/dev/null | grep -q / ; then
		if command -v yay &>/dev/null ; then
			PKG="${PKG/default-jdk/jdk-openjdk}"
			yay -S "$PKG"
		elif command -v "dnf" &>/dev/null ; then
			if type manualInstall &>/dev/null ; then
				manualInstall
			else
				sudo dnf install "$PKG"
			fi
		elif command -v apt &>/dev/null ; then
			if type manualInstall &>/dev/null ; then
				manualInstall
			else
				sudo apt install "$PKG"
			fi
		else
			if type manualInstall &>/dev/null ; then
				manualInstall
			else
				echo "Install $PKG/$CMD first." >&2
				exit 1
			fi
		fi
	fi
}
