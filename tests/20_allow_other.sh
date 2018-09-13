
function setup() {
    mount_dir=$(mktemp -d)
    $SPARSEBUNDLEFS -s -f -D -o allow_other $TEST_BUNDLE $mount_dir &
    for i in {0..50}; do
        # FIXME: Find actual mount callback in fuse?
        grep -q "bundle has" $test_output_file && break || sleep 0.1
    done
    pid=$!
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
