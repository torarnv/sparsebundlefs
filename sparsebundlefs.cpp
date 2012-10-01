#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <fuse.h>
#include <inttypes.h>
#include <stdlib.h>
#include <stdio.h>

#include <string>
#include <fstream>
#include <sstream>
#include <streambuf>
#include <iostream>

static const char *image_path = "/sparsebundle.dmg";

struct sparsebundle_data {
    char *path;
    off_t band_size;
    off_t size;
    FILE* logfile;
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

    return 0;
}

static void log(const char *format, ...)
{
    va_list ap;
    va_start(ap, format);

    vfprintf(SB_DATA->logfile, format, ap);
}

static int sparsebundle_read(const char *path, char *buffer, size_t length, off_t offset,
           struct fuse_file_info *fi)
{
    if (strcmp(path, image_path) != 0)
        return -ENOENT;

    if (offset >= SB_DATA->size)
        return 0;

    if (offset + length > SB_DATA->size)
        length = SB_DATA->size - offset;

    log("sparsebundle_read(length: %zu offfset: %llu\n", length, offset);

    size_t bytes_read = 0;
    while (bytes_read < length) {
        off_t band_number = (offset + bytes_read) / SB_DATA->band_size;
        off_t band_offset = (offset + bytes_read) % SB_DATA->band_size;

        ssize_t to_read = length - bytes_read;

        char *band_name;
        asprintf(&band_name, "%s/bands/%llx", SB_DATA->path, band_number);

        log("\tReading band %llx at offet %llu (bytes_read: %zu to_read: %zu\n",
            band_number, band_offset, bytes_read, to_read);

        ssize_t read = 0;
        int band_file = open(band_name, O_RDONLY);
        if (band_file != -1) {
            read = pread(band_file, buffer + bytes_read, to_read, band_offset);
            close(band_file);

            if (read == -1) {
                log("! Failed to read %zu bytes from band file %s at offset %llu\n",
                    to_read, band_name, band_offset);
                free(band_name);
                return -1;
            }
        } else if (errno != ENOENT) {
            log("! Failed to open band file %s %d\n", band_name, errno);
            free(band_name);
            return -1;
        }

        free(band_name);

        if (read < to_read) {
            log("! EOB, read: %zu, padding with zeroes\n", read);
            // Hit missing band or end of band, pad with zeroes
            memset(buffer + bytes_read + read, 0, to_read - read);
        }

        bytes_read += to_read;
    }

    assert(bytes_read == length);
    return bytes_read;
}

static int sparsebundle_show_usage(char* program_name)
{
    fprintf(stderr, "usage: %s [-o options] sparsebundle mountpoint\n", program_name);
    return 1;
}

static int sparsebundle_opt_proc(void *data, const char *arg, int key, struct fuse_args *outargs)
{
    if (key == FUSE_OPT_KEY_NONOPT && !SB_DATA_CAST(data)->path) {
        SB_DATA_CAST(data)->path = strdup(arg);
        return 0;
    }

    return 1;
}

using namespace std;

static off_t read_size(const string &str)
{
    uintmax_t value = strtoumax(str.c_str(), 0, 10);
    if (errno == ERANGE || value > static_cast<uintmax_t>(numeric_limits<off_t>::max())) {
        fprintf(stderr, "Disk image too large to be mounted (%s bytes)\n", str.c_str());
        exit(-1);
    }

    return value;
}

int main(int argc, char **argv)
{
    struct sparsebundle_data data = {};

    data.logfile = fopen("/tmp/sparesebundlefs.log", "w");
    setvbuf(data.logfile, 0, _IOLBF, 0);

    struct fuse_args args = FUSE_ARGS_INIT(argc, argv);
    fuse_opt_parse(&args, &data, 0, sparsebundle_opt_proc);

    if (!data.path)
        return sparsebundle_show_usage(argv[0]);

    char *abs_path = realpath(data.path, 0);
    if (!abs_path) {
        perror("Could not resolve absolute path");
        return -1;
    }

    free(data.path);
    data.path = abs_path;

    char *plist_path;
    asprintf(&plist_path, "%s/Info.plist", data.path);

    ifstream plist_file(plist_path);
    stringstream plist_data;
    plist_data << plist_file.rdbuf();

    string key, line;
    while (getline(plist_data, line)) {
        static const char *whitespace_chars = " \n\r\t";
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

    struct fuse_operations sparsebundle_filesystem_operations = {};
    sparsebundle_filesystem_operations.getattr = sparsebundle_getattr;
    sparsebundle_filesystem_operations.open = sparsebundle_open;
    sparsebundle_filesystem_operations.read = sparsebundle_read;
    sparsebundle_filesystem_operations.readdir = sparsebundle_readdir;

    int ret = fuse_main(args.argc, args.argv, &sparsebundle_filesystem_operations, &data);

    fuse_opt_free_args(&args);
    return ret;
}
