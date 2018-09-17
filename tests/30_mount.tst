#!/usr/bin/env testrunner.sh

source "$(dirname "$0")/testhelpers.sh"

function setup() {
    mount_sparsebundle
}

function test_dmg_info() {
    hfsdump $dmg_file
}

function teardown() {
    umount $mount_dir
    rm -Rf $mount_dir
}
