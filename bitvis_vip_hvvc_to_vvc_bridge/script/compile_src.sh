#!/usr/bin/env bash

wrk=work

while getopts ":w:" opt; do
	case $opt in 
		w) wrk=$OPTARG
		echo "-- compiling into '$wrk'"
		;;
		\?) echo "invalid option -$OPTARG"
		exit 1
		;;
	esac

	case $OPTARG in 
		-*) echo "invalid value provided for $opt"
		exit 1
		;;
	esac
done

SCRIPT_PATH=$(realpath -s "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
FILES=$(cat "$SCRIPT_DIR/compile_order.txt" | sed -r 's/#.*//g')
COMPILE='ghdl -a --std=08 -frelaxed --work=$wrk'

for f in $FILES; do
	if [ x$f == x"" ]; then continue; fi

	pth="$SCRIPT_DIR/$f"

	echo "-- running '$COMPILE $SCRIPT_DIR/$f'"
	eval "$COMPILE \"$SCRIPT_DIR/$f\""
done
