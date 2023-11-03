#!/usr/bin/env bash

SCRIPT_DIR=$(dirname "$(realpath -s ${0})")
MODULES=$(cat "$SCRIPT_DIR/component_list.txt" | sed -r 's/#.*//g')

echo "dir: $SCRIPT_DIR"

echo "modules: $MODULES"


for m in $MODULES; do
	if [ x$m == x"" ]; then continue; fi

	pth="$SCRIPT_DIR/../$m/script/compile_src.sh"
	
	if [ -x "$pth" ]; then
		compile_command="\"$pth\" -w $m"

		echo "-- running '$compile_command'"
		eval "$compile_command"
	fi
done
