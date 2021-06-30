#!/usr/bin/env testrunner.sh

source "$(dirname "$0")/testhelpers.sh"

mount_options="-o noreadbuf"

function setup() {
    read -r mount_dir dmg_file < <(mount_sparsebundle $mount_options)
}

function test_dmg_has_correct_number_of_blocks() {
    _test_dmg_has_correct_number_of_blocks
}

function test_dmg_contents_is_same_as_testdata() {
	_test_dmg_contents_is_same_as_testdata
}

function test_can_handle_ulimit() {
	_test_can_handle_ulimit
}

function teardown() {
    umount $mount_dir && rm -Rf $mount_dir
}
