#!/usr/bin/env testrunner.sh

source "$(dirname "$0")/testhelpers.sh"

function setup() {
    mount_sparsebundle -o noreadbuf
}

function test_dmg_has_correct_number_of_blocks() {
    hfsdump $dmg_file | grep "total_blocks: 268435456"
}

function test_dmg_contents_is_same_as_testdata() {
    for f in $(ls $HFSFUSE_DIR/src); do
        echo "Diffing $HFSFUSE_DIR/src/$f"
        diff $HFSFUSE_DIR/src/$f <(hfsdump $dmg_file read "/src/$f")
    done
}

function teardown() {
    umount $mount_dir
    rm -Rf $mount_dir
}