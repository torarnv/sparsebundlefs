#!/usr/bin/env testrunner.sh

source "$(dirname "$0")/testhelpers.sh"

function setup() {
    mount_sparsebundle -o allow_other
}

function test_dmg_has_correct_permissions() {
    permissions=$(ls -l $dmg_file | awk '{print $1; exit}')
    test $permissions = "-r-----r--"
}

function teardown() {
    umount $mount_dir && rm -Rf $mount_dir
}
