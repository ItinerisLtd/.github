#!/usr/bin/env bash

read_newline_list() {
	local NAME="$1"
	local VALUE="$2"

	mapfile -t "$NAME" < <(printf '%s\n' "$VALUE" | tr -d '[:blank:]\r' | sed '/^$/d')
}
