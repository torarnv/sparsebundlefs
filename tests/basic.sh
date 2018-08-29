#!/bin/bash

function setup() {
	sleep 5 & disown
}

function test_dmg_exists_after_mounting() {
	echo "  hei stdout"
	echo "  hei stderr" >&2
	echo hallo
	test 1 -eq 1 # && false
	#return 6
	sleep 4
	#test 3 -eq 6
	echo -n oops
	#faen_da
	#test 1 -eq 2
}

function test_size_after_mounting_is_correct() {
	a=foo
	#test $a = "hei"
	echo faen
}
