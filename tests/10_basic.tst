#!/usr/bin/env testrunner.sh

source "$(dirname "$0")/testhelpers.sh"

function setup() {
    mount_sparsebundle
}

function test_dmg_exists_after_mounting() {
    ls -al $mount_dir
    test -f $dmg_file
}

function test_dmg_has_expected_size() {
    size=$(ls -dn $dmg_file | awk '{print $5; exit}')
    test $size -eq 1099511627776
}

function test_dmg_has_correct_owner() {
    owner=$(ls -l $dmg_file | awk '{print $3; exit}')
    test $owner = $(whoami)
}

function test_dmg_has_correct_permissions() {
    permissions=$(ls -l $dmg_file | awk '{print $1; exit}')
    test $permissions = "-r--------"
}

function teardown() {
    umount $mount_dir
    rm -Rf $mount_dir
}
