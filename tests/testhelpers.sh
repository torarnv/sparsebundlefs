
function mount_sparsebundle() {
    test ! -z "$TEST_BUNDLE"
    mount_dir=$(mktemp -d)
    dmg_file="$mount_dir/sparsebundle.dmg"
    sparsebundlefs -s -f -D $* $TEST_BUNDLE $mount_dir &
    pid=$!
    for i in {0..50}; do
        kill -0 $pid >/dev/null 2>&1
        test -f $dmg_file && break || sleep 0.1
    done
}
