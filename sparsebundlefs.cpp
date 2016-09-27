/*
 * Copyright (c) 2012-2016 Tor Arne Vestbø. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 *    list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <syslog.h>
#include <string.h>
#include <unistd.h>
#include <sys/resource.h>

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

#define FUSE_SUPPORTS_ZERO_COPY FUSE_VERSION >= 29

using namespace std;

static const char image_path[] = "/sparsebundle.dmg";

struct sparsebundle_t {
    char *path;
    char *mountpoint;
    off_t band_size;
    off_t size;
    off_t times_opened;
#if FUSE_SUPPORTS_ZERO_COPY
    map<string, int> open_files;
#endif
};

#define sparsebundle_current() \
    static_cast<sparsebundle_t *>(fuse_get_context()->private_data)

static int sparsebundle_getattr(const char *path, struct stat *stbuf)
{
    sparsebundle_t *sparsebundle = sparsebundle_current();

    memset(stbuf, 0, sizeof(struct stat));

    struct stat bundle_stat;
    stat(sparsebundle->path, &bundle_stat);

    if (strcmp(path, "/") == 0) {
        stbuf->st_mode = S_IFDIR | 0555;
        stbuf->st_nlink = 3;
        stbuf->st_size = sizeof(sparsebundle_t);
    } else if (strcmp(path, image_path) == 0) {
        stbuf->st_mode = S_IFREG | 0444;
        stbuf->st_nlink = 1;
        stbuf->st_size = sparsebundle->size;
    } else
        return -ENOENT;

    stbuf->st_atime = bundle_stat.st_atime;
    stbuf->st_mtime = bundle_stat.st_mtime;
    stbuf->st_ctime = bundle_stat.st_ctime;

    return 0;
}

static int sparsebundle_readdir(const char *path, void *buf, fuse_fill_dir_t filler,
              off_t /* offset */, struct fuse_file_info *)
{
    if (strcmp(path, "/") != 0)
        return -ENOENT;

    struct stat image_stat;
    sparsebundle_getattr(image_path, &image_stat);

    filler(buf, ".", 0, 0);
    filler(buf, "..", 0, 0);
    filler(buf, image_path + 1, &image_stat, 0);

    return 0;
}

static int sparsebundle_open(const char *path, struct fuse_file_info *fi)
{
    if (strcmp(path, image_path) != 0)
        return -ENOENT;

    if ((fi->flags & O_ACCMODE) != O_RDONLY)
        return -EACCES;

    sparsebundle_t *sparsebundle = sparsebundle_current();

    sparsebundle->times_opened++;
    syslog(LOG_DEBUG, "opened %s%s, now referenced %ju times",
        sparsebundle->mountpoint, path, uintmax_t(sparsebundle->times_opened));

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

    sparsebundle_t *sparsebundle = sparsebundle_current();

    if (offset >= sparsebundle->size)
        return 0;

    if (offset + length > sparsebundle->size)
        length = sparsebundle->size - offset;

    syslog(LOG_DEBUG, "iterating %zu bytes at offset %ju", length, uintmax_t(offset));

    size_t bytes_read = 0;
    while (bytes_read < length) {
        off_t band_number = (offset + bytes_read) / sparsebundle->band_size;
        off_t band_offset = (offset + bytes_read) % sparsebundle->band_size;

        ssize_t to_read = min(static_cast<off_t>(length - bytes_read),
            sparsebundle->band_size - band_offset);

        char *band_path;
        if (asprintf(&band_path, "%s/bands/%jx", sparsebundle->path, uintmax_t(band_number)) == -1) {
            syslog(LOG_ERR, "failed to resolve band name");
            return -errno;
        }

        syslog(LOG_DEBUG, "processing %zu bytes from band %jx at offset %ju",
            to_read, uintmax_t(band_number), uintmax_t(band_offset));

        ssize_t read = read_ops->process_band(band_path, to_read, band_offset, read_ops->data);
        if (read < 0) {
            free(band_path);
            return -errno;
        }

        free(band_path);

        if (read < to_read) {
            to_read = to_read - read;
            syslog(LOG_DEBUG, "missing %zu bytes from band %jx, padding with zeroes",
                to_read, uintmax_t(band_number));
            read += read_ops->pad_with_zeroes(to_read, read_ops->data);
        }

        bytes_read += read;

        syslog(LOG_DEBUG, "done processing band %jx, %zu bytes left to read",
                uintmax_t(band_number), length - bytes_read);
    }

    assert(bytes_read == length);
    return bytes_read;
}

static int sparsebundle_read_process_band(const char *band_path, size_t length, off_t offset, void *read_data)
{
    ssize_t read = 0;

    char** buffer = static_cast<char**>(read_data);

    syslog(LOG_DEBUG, "reading %zu bytes at offset %ju into %p",
        length, uintmax_t(offset), *buffer);

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

    return length;
}

static int sparsebundle_read(const char *path, char *buffer, size_t length, off_t offset,
           struct fuse_file_info *)
{
    sparsebundle_read_operations read_ops = {
        &sparsebundle_read_process_band,
        sparsebundle_read_pad_with_zeroes,
        &buffer
    };

    syslog(LOG_DEBUG, "asked to read %zu bytes at offset %ju", length, uintmax_t(offset));

    return sparsebundle_iterate_bands(path, length, offset, &read_ops);
}

#if FUSE_SUPPORTS_ZERO_COPY
static int sparsebundle_read_buf_prepare_file(const char *path)
{
    sparsebundle_t *sparsebundle = sparsebundle_current();

    int fd = -1;
    map<string, int>::const_iterator iter = sparsebundle->open_files.find(path);
    if (iter != sparsebundle->open_files.end()) {
        fd = iter->second;
    } else {
        syslog(LOG_DEBUG, "file %s not opened yet, opening", path);
        fd = open(path, O_RDONLY);
        sparsebundle->open_files[path] = fd;
    }

    return fd;
}

static int sparsebundle_read_buf_process_band(const char *band_path, size_t length, off_t offset, void *read_data)
{
    ssize_t read = 0;

    vector<fuse_buf> *buffers = static_cast<vector<fuse_buf>*>(read_data);

    syslog(LOG_DEBUG, "preparing %zu bytes at offset %ju", length,
        uintmax_t(offset));

    int band_file_fd = sparsebundle_read_buf_prepare_file(band_path);
    if (band_file_fd != -1) {
        struct stat band_stat;
        stat(band_path, &band_stat);
        read += max(off_t(0), min(static_cast<off_t>(length), band_stat.st_size - offset));
    } else if (errno != ENOENT) {
        syslog(LOG_ERR, "failed to open band %s: %s", band_path, strerror(errno));
        return -errno;
    }

    if (read > 0) {
        fuse_buf buffer = { read, fuse_buf_flags(FUSE_BUF_IS_FD | FUSE_BUF_FD_SEEK), 0, band_file_fd, offset };
        buffers->push_back(buffer);
    }

    return read;
}

static const char zero_device[] = "/dev/zero";

static int sparsebundle_read_buf_pad_with_zeroes(size_t length, void *read_data)
{
    vector<fuse_buf> *buffers = static_cast<vector<fuse_buf>*>(read_data);
    int zero_device_fd = sparsebundle_read_buf_prepare_file(zero_device);
    fuse_buf buffer = { length, fuse_buf_flags(FUSE_BUF_IS_FD), 0, zero_device_fd, 0 };
    buffers->push_back(buffer);

    return length;
}

static void sparsebundle_read_buf_close_files()
{
    sparsebundle_t *sparsebundle = sparsebundle_current();

    syslog(LOG_DEBUG, "closing %u open file descriptor(s)", sparsebundle->open_files.size());

    map<string, int>::iterator iter;
    for(iter = sparsebundle->open_files.begin(); iter != sparsebundle->open_files.end(); ++iter) {
        close(iter->second);
        syslog(LOG_DEBUG, "closed %s", iter->first.c_str());
    }

    sparsebundle->open_files.clear();
}

static int sparsebundle_read_buf(const char *path, struct fuse_bufvec **bufp,
                        size_t length, off_t offset, struct fuse_file_info *)
{
    int ret = 0;

    vector<fuse_buf> buffers;

    sparsebundle_read_operations read_ops = {
        &sparsebundle_read_buf_process_band,
        sparsebundle_read_buf_pad_with_zeroes,
        &buffers
    };

    syslog(LOG_DEBUG, "asked to read %zu bytes at offset %ju using zero-copy read",
        length, uintmax_t(offset));

    static struct rlimit fd_limit;
    static bool fd_limit_computed = false;
    if (!fd_limit_computed) {
        getrlimit(RLIMIT_NOFILE, &fd_limit);
        fd_limit_computed = true;
    }

    sparsebundle_t *sparsebundle = sparsebundle_current();
    if (sparsebundle->open_files.size() + 1 >= fd_limit.rlim_cur) {
        syslog(LOG_DEBUG, "hit max number of file descriptors");
        sparsebundle_read_buf_close_files();
    }

    ret = sparsebundle_iterate_bands(path, length, offset, &read_ops);
    if (ret < 0)
        return ret;

    size_t bufvec_size = sizeof(struct fuse_bufvec) + (sizeof(struct fuse_buf) * (buffers.size() - 1));
    struct fuse_bufvec *buffer_vector = static_cast<fuse_bufvec*>(malloc(bufvec_size));
    if (buffer_vector == 0)
        return -ENOMEM;

    buffer_vector->count = buffers.size();
    buffer_vector->idx = 0;
    buffer_vector->off = 0;

    copy(buffers.begin(), buffers.end(), buffer_vector->buf);

    syslog(LOG_DEBUG, "returning %d buffers to fuse", buffer_vector->count);
    *bufp = buffer_vector;

    return ret;
}
#endif

static int sparsebundle_release(const char *path, struct fuse_file_info *)
{
    sparsebundle_t *sparsebundle = sparsebundle_current();

    sparsebundle->times_opened--;
    syslog(LOG_DEBUG, "closed %s%s, now referenced %ju times",
        sparsebundle->mountpoint, path, uintmax_t(sparsebundle->times_opened));

    if (sparsebundle->times_opened == 0) {
        syslog(LOG_DEBUG, "no more references, cleaning up");

#if FUSE_SUPPORTS_ZERO_COPY
        if (!sparsebundle->open_files.empty())
            sparsebundle_read_buf_close_files();
#endif
    }

    return 0;
}

__attribute__((noreturn, format(printf, 1, 2))) static void sparsebundle_fatal_error(const char *message, ...)
{
    fprintf(stderr, "sparsebundlefs: ");

    va_list args;
    va_start(args, message);
    vfprintf(stderr, message, args);
    va_end(args);

    if (errno)
        fprintf(stderr, ": %s", strerror(errno));

    fprintf(stderr, "\n");

    exit(EXIT_FAILURE);
}

static int sparsebundle_show_usage(char *program_name)
{
    fprintf(stderr, "usage: %s [-o options] [-s] [-f] [-D] <sparsebundle> <mountpoint>\n", program_name);
    return 1;
}

enum { SPARSEBUNDLE_OPT_DEBUG = 0, SPARSEBUNDLE_OPT_HANDLED = 0, SPARSEBUNDLE_OPT_IGNORED = 1 };

static int sparsebundle_opt_proc(void *data, const char *arg, int key, struct fuse_args *outargs)
{
    switch (key) {
    case SPARSEBUNDLE_OPT_DEBUG:
        setlogmask(LOG_UPTO(LOG_DEBUG));
        return SPARSEBUNDLE_OPT_HANDLED;

    case FUSE_OPT_KEY_NONOPT:
        sparsebundle_t *sparsebundle = static_cast<sparsebundle_t *>(data);

        if (!sparsebundle->path) {
            sparsebundle->path = realpath(arg, 0);
            if (!sparsebundle->path)
                sparsebundle_fatal_error("bad sparse-bundle `%s'", arg);
            return SPARSEBUNDLE_OPT_HANDLED;
        } else if (!sparsebundle->mountpoint) {
            sparsebundle->mountpoint = realpath(arg, 0);
            if (!sparsebundle->mountpoint)
                sparsebundle_fatal_error("bad mount point `%s'", arg);
            fuse_opt_add_arg(outargs, sparsebundle->mountpoint);
            return SPARSEBUNDLE_OPT_HANDLED;
        }

        return SPARSEBUNDLE_OPT_IGNORED;
    }

    return SPARSEBUNDLE_OPT_IGNORED;
}

static off_t read_size(const string &str)
{
    uintmax_t value = strtoumax(str.c_str(), 0, 10);
    if (errno == ERANGE || value > uintmax_t(numeric_limits<off_t>::max()))
        sparsebundle_fatal_error("disk image too large (%s bytes)", str.c_str());

    return value;
}

int main(int argc, char **argv)
{
    openlog("sparsebundlefs", LOG_CONS | LOG_PERROR, LOG_USER);
    setlogmask(~(LOG_MASK(LOG_DEBUG)));

    struct sparsebundle_t sparsebundle = {};

    static struct fuse_opt sparsebundle_options[] = {
        FUSE_OPT_KEY("-D",  SPARSEBUNDLE_OPT_DEBUG),
        { 0, 0, 0 } // End of options
    };

    struct fuse_args args = FUSE_ARGS_INIT(argc, argv);
    fuse_opt_parse(&args, &sparsebundle, sparsebundle_options, sparsebundle_opt_proc);
    fuse_opt_add_arg(&args, "-oro"); // Force read-only mount

    if (!sparsebundle.path || !sparsebundle.mountpoint)
        return sparsebundle_show_usage(argv[0]);

    syslog(LOG_DEBUG, "mounting `%s' at mount-point `%s'",
        sparsebundle.path, sparsebundle.mountpoint);

    char *plist_path;
    if (asprintf(&plist_path, "%s/Info.plist", sparsebundle.path) == -1)
        sparsebundle_fatal_error("could not resolve Info.plist path");

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
                sparsebundle.band_size = read_size(line);
            else if (key == "size")
                sparsebundle.size = read_size(line);

            key.clear();
        }
    }

    syslog(LOG_DEBUG, "bundle has band size %ju and total size %ju",
        uintmax_t(sparsebundle.band_size), uintmax_t(sparsebundle.size));

    struct fuse_operations sparsebundle_filesystem_operations = {};
    sparsebundle_filesystem_operations.getattr = sparsebundle_getattr;
    sparsebundle_filesystem_operations.open = sparsebundle_open;
    sparsebundle_filesystem_operations.read = sparsebundle_read;
    sparsebundle_filesystem_operations.readdir = sparsebundle_readdir;
    sparsebundle_filesystem_operations.release = sparsebundle_release;
#if FUSE_SUPPORTS_ZERO_COPY
    sparsebundle_filesystem_operations.read_buf = sparsebundle_read_buf;
#endif

    return fuse_main(args.argc, args.argv, &sparsebundle_filesystem_operations, &sparsebundle);
}
