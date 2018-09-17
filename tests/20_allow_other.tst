#!/usr/bin/env testrunner.sh

function setup() {
    test ! -z "$TEST_BUNDLE"
    mount_dir=$(mktemp -d)
    sparsebundlefs -s -f -D -o allow_other $TEST_BUNDLE $mount_dir &
    pid=$!
    for i in {0..50}; do
        kill -0 $pid >/dev/null 2>&1
        # FIXME: Find actual mount callback in fuse?
        grep -q "bundle has" $test_output_file && break || sleep 0.1
    done
    dmg_file=$mount_dir/sparsebundle.dmg
}

function test_dmg_has_correct_permissions() {
    permissions=$(ls -l $dmg_file | awk '{print $1; exit}')
    test $permissions = "-r-----r--"
}

function teardown() {
    umount $mount_dir
    rm -Rf $mount_dir
}
