
function mount_sparsebundle() {
    test ! -z "$TEST_BUNDLE"
    mount_dir=$(mktemp -d)
    sparsebundlefs -s -f -D $* $TEST_BUNDLE $mount_dir &
    pid=$!
    for i in {0..50}; do
        kill -0 $pid >/dev/null 2>&1
        # FIXME: Find actual mount callback in fuse?
        grep -q "bundle has" $test_output_file && break || sleep 0.1
    done
    dmg_file=$mount_dir/sparsebundle.dmg
}
