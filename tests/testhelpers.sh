
sparsebundlefs_ulimit=

function mount_sparsebundle() {
    test ! -z "$TEST_BUNDLE"
    local mount_dir=$(mktemp -d)
    local dmg_file="$mount_dir/sparsebundle.dmg"
    (
        if [[ ! -z "${sparsebundlefs_ulimit}" ]]; then
            ulimit -n $sparsebundlefs_ulimit
        fi
        sparsebundlefs -s -f -D $* $TEST_BUNDLE $mount_dir
    ) &
    local pid=$!
    for i in {0..50}; do
        kill -0 $pid >/dev/null 2>&1
        test -f $dmg_file && break || sleep 0.1
    done

    echo $mount_dir "$mount_dir/sparsebundle.dmg"
}

function _test_dmg_has_correct_number_of_blocks() {
    hfsdump $dmg_file | grep "total_blocks: 268435456"
}

function _test_dmg_contents_is_same_as_testdata() {
    for f in $HFSFUSE_DIR/src/*; do
        f=$(basename $f)
        echo "Diffing $HFSFUSE_DIR/src/$f"
        diff $HFSFUSE_DIR/src/$f <(hfsdump $dmg_file read "/src/$f")
    done
}

function _test_can_handle_ulimit() {
    local mount_dir
    local dmg_file


    sparsebundlefs_ulimit=12
    read -r mount_dir dmg_file < <(mount_sparsebundle $mount_options)
    sparsebundlefs_ulimit=

    hfs_dir=$(mktemp -d)
    hfsfuse -f $dmg_file $hfs_dir &
    local hfs_pid=$!
    for i in {0..50}; do
        kill -0 $hfs_pid >/dev/null 2>&1
        test -f $hfs_dir/Makefile && break || sleep 0.1
    done

    for f in $(find $hfs_dir -type f); do
        echo "Reading $f"
        cat $f > /dev/null
    done

    grep -q "too many open file descriptors" $test_output_file

    umount $hfs_dir && rm -Rf $hfs_dir
    umount $mount_dir && rm -Rf $mount_dir
}
