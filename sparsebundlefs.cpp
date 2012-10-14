#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <syslog.h>
#include <string.h>

#include <algorithm>
#include <fstream>
#include <iostream>
#include <limits>
#include <map>
#include <sstream>
#include <streambuf>
#include <string>
#include <vector>

#include <fuse.h>

using namespace std;

static const char image_path[] = "/sparsebundle.dmg";

struct sparsebundle_data {
    char *path;
    off_t band_size;
    off_t size;
    off_t times_opened;
};

#define SB_DATA_CAST(ptr) ((struct sparsebundle_data *) ptr)
#define SB_DATA (SB_DATA_CAST(fuse_get_context()->private_data))

static int sparsebundle_readdir(const char *path, void *buf, fuse_fill_dir_t filler,
              off_t offset, struct fuse_file_info *fi)
{
    if (strcmp(path, "/") != 0)
        return -ENOENT;

    filler(buf, ".", 0, 0);
    filler(buf, "..", 0, 0);
    filler(buf, image_path + 1, 0, 0);

    return 0;
}

static int sparsebundle_getattr(const char *path, struct stat *stbuf)
{
    memset(stbuf, 0, sizeof(struct stat));

    if (strcmp(path, "/") == 0) {
        stbuf->st_mode = S_IFDIR | 0755;
        stbuf->st_nlink = 3;
    } else if (strcmp(path, image_path) == 0) {
        stbuf->st_mode = S_IFREG | 0444;
        stbuf->st_nlink = 1;
        stbuf->st_size = SB_DATA->size;
    } else
        return -ENOENT;

    return 0;
}

static int sparsebundle_open(const char *path, struct fuse_file_info *fi)
{
    if (strcmp(path, image_path) != 0)
        return -ENOENT;

    if ((fi->flags & O_ACCMODE) != O_RDONLY)
        return -EACCES;

    SB_DATA->times_opened++;
    syslog(LOG_DEBUG, "opened %s, now referenced %llx times",
        SB_DATA->path, SB_DATA->times_opened);

    return 0;
}

struct sparsebundle_read_operations {
    int (*process_band) (const char *, size_t, off_t, void*);
    int (*pad_with_zeroes) (size_t, void*);
    void *data;
};

static int sparsebundle_iterate_bands(const char *path, size_t length, off_t offset,
           struct sparsebundle_read_operations *read_ops)
{
    if (strcmp(path, image_path) != 0)
        return -ENOENT;

    if (offset >= SB_DATA->size)
        return 0;

    if (offset + length > SB_DATA->size)
        length = SB_DATA->size - offset;

    syslog(LOG_DEBUG, "iterating %zu bytes at offset %llu", length, offset);

    size_t bytes_read = 0;
    while (bytes_read < length) {
        off_t band_number = (offset + bytes_read) / SB_DATA->band_size;
        off_t band_offset = (offset + bytes_read) % SB_DATA->band_size;

        ssize_t to_read = min(static_cast<off_t>(length - bytes_read),
            SB_DATA->band_size - band_offset);

        char *band_path;
        if (asprintf(&band_path, "%s/bands/%llx", SB_DATA->path, band_number) == -1) {
            syslog(LOG_ERR, "failed to resolve band name");
            return -errno;
        }

        syslog(LOG_DEBUG, "processing %zu bytes from band %llx at offset %llu",
            to_read, band_number, band_offset);

        ssize_t read = read_ops->process_band(band_path, to_read, band_offset, read_ops->data);
        if (read < 0) {
            free(band_path);
            return -errno;
        }

        free(band_path);

        if (read < to_read) {
            to_read = to_read - read;
            syslog(LOG_DEBUG, "missing %zu bytes from band %llx, padding with zeroes",
                to_read, band_number);
            read_ops->pad_with_zeroes(to_read, read_ops->data);
            read += to_read;
        }

        bytes_read += read;

        syslog(LOG_DEBUG, "done processing band %llx, %zu bytes left to read",
                band_number, length - bytes_read);
    }

    assert(bytes_read == length);
    return bytes_read;
}

static int sparsebundle_read_process_band(const char *band_path, size_t length, off_t offset, void *read_data)
{
    size_t read = 0;

    char** buffer = static_cast<char**>(read_data);

    syslog(LOG_DEBUG, "reading %zu bytes at offset %llu into %p",
        length, offset, *buffer);

    int band_file = open(band_path, O_RDONLY);
    if (band_file != -1) {
        read = pread(band_file, *buffer, length, offset);
        close(band_file);

        if (read == -1) {
            syslog(LOG_ERR, "failed to read band: %s", strerror(errno));
            return -errno;
        }
    } else if (errno != ENOENT) {
        syslog(LOG_ERR, "failed to open band %s: %s", band_path, strerror(errno));
        return -errno;
    }

    *buffer += read;

    return read;
}

static int sparsebundle_read_pad_with_zeroes(size_t length, void *read_data)
{
    char** buffer = static_cast<char**>(read_data);

    syslog(LOG_DEBUG, "padding %zu bytes of zeroes into %p", length, *buffer);

    memset(*buffer, 0, length);
    *buffer += length;

    return 0;
}

static int sparsebundle_read(const char *path, char *buffer, size_t length, off_t offset,
           struct fuse_file_info *fi)
{
    sparsebundle_read_operations read_ops = {
        &sparsebundle_read_process_band,
        sparsebundle_read_pad_with_zeroes,
        &buffer
    };

    syslog(LOG_DEBUG, "asked to read %zu bytes at offset %llu", length, offset);

    return sparsebundle_iterate_bands(path, length, offset, &read_ops);
}

static int sparsebundle_release(const char *path, struct fuse_file_info *fi)
{
    SB_DATA->times_opened--;
    syslog(LOG_DEBUG, "closed %s, now referenced %llx times",
        SB_DATA->path, SB_DATA->times_opened);

    if (SB_DATA->times_opened == 0) {
        syslog(LOG_DEBUG, "no more references to sparsebundle, cleaning up");
    }

    return 0;
}

static int sparsebundle_show_usage(char *program_name)
{
    fprintf(stderr, "usage: %s [-o options] [-f] [-D] <sparsebundle> <mountpoint>\n", program_name);
    return 1;
}

enum { SPARSEBUNDLE_OPT_DEBUG };

static int sparsebundle_opt_proc(void *data, const char *arg, int key, struct fuse_args *outargs)
{
    switch (key) {
    case SPARSEBUNDLE_OPT_DEBUG:
        setlogmask(LOG_UPTO(LOG_DEBUG));
        return 0;
    case FUSE_OPT_KEY_NONOPT:
        if (SB_DATA_CAST(data)->path)
            return 1;

        SB_DATA_CAST(data)->path = strdup(arg);
        return 0;
    }

    return 1;
}

static off_t read_size(const string &str)
{
    uintmax_t value = strtoumax(str.c_str(), 0, 10);
    if (errno == ERANGE || value > static_cast<uintmax_t>(numeric_limits<off_t>::max())) {
        fprintf(stderr, "Disk image too large to be mounted (%s bytes)\n", str.c_str());
        exit(EXIT_FAILURE);
    }

    return value;
}

int main(int argc, char **argv)
{
    openlog("sparsebundlefs", LOG_CONS | LOG_PERROR, LOG_USER);
    setlogmask(~(LOG_MASK(LOG_DEBUG)));

    struct sparsebundle_data data = {};

    static struct fuse_opt sparsebundle_options[] = {
        FUSE_OPT_KEY("-D",  SPARSEBUNDLE_OPT_DEBUG), FUSE_OPT_END
    };

    struct fuse_args args = FUSE_ARGS_INIT(argc, argv);
    fuse_opt_parse(&args, &data, sparsebundle_options, sparsebundle_opt_proc);
    fuse_opt_add_arg(&args, "-oro"); // Force read-only mount

    if (!data.path)
        return sparsebundle_show_usage(argv[0]);

    char *abs_path = realpath(data.path, 0);
    if (!abs_path) {
        perror("Could not resolve absolute path");
        return EXIT_FAILURE;
    }

    free(data.path);
    data.path = abs_path;

    char *plist_path;
    if (asprintf(&plist_path, "%s/Info.plist", data.path) == -1) {
        perror("Failed to resolve Info.plist path");
        return EXIT_FAILURE;
    }

    ifstream plist_file(plist_path);
    stringstream plist_data;
    plist_data << plist_file.rdbuf();

    string key, line;
    while (getline(plist_data, line)) {
        static const char whitespace_chars[] = " \n\r\t";
        line.erase(0, line.find_first_not_of(whitespace_chars));
        line.erase(line.find_last_not_of(whitespace_chars) + 1);

        if (line.compare(0, 5, "<key>") == 0) {
            key = line.substr(5, line.length() - 11);
        } else if (!key.empty()) {
            line.erase(0, line.find_first_of('>') + 1);
            line.erase(line.find_first_of('<'));

            if (key == "band-size")
                data.band_size = read_size(line);
            else if (key == "size")
                data.size = read_size(line);

            key.clear();
        }
    }

    syslog(LOG_DEBUG, "initialized %s, band size %llu, total size %llu",
        data.path, data.band_size, data.size);

    struct fuse_operations sparsebundle_filesystem_operations = {};
    sparsebundle_filesystem_operations.getattr = sparsebundle_getattr;
    sparsebundle_filesystem_operations.open = sparsebundle_open;
    sparsebundle_filesystem_operations.read = sparsebundle_read;
    sparsebundle_filesystem_operations.readdir = sparsebundle_readdir;
    sparsebundle_filesystem_operations.release = sparsebundle_release;

    return fuse_main(args.argc, args.argv, &sparsebundle_filesystem_operations, &data);
}
