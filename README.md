sparsebundlefs
================

FUSE filesystem for reading Mac OS sparse-bundle disk images.

Mac OS X v10.5 (Leopard) introduced the concept of sparse-bundle disk images, where the data is
stored as a set of small fixed-size *band* files instead of as a single monolithic file. This
allows for more effective backups of the disk image, as only the changed bands need to be
stored.

One common client of sparse-bundles is Mac OS's backup utility, *Time Machine*, which stores
the backup data within a sparse-bundle image on the chosen backup volume.

This software package implements a FUSE virtual filesystem for read-only access to the sparse-
bundle, as if it was a single monolithic image.

Installation
------------

Clone the project from GitHub:

    git clone git://github.com/torarnv/sparsebundlefs.git

Or download the latest tar-ball:

    curl -L https://github.com/torarnv/sparsebundlefs/tarball/master | tar xvz

Install dependencies:

  - [OSXFUSE][osxfuse] on *Mac OS X*
  - `apt get install libfuse-dev libfuse2 fuse-utils` on Debian-based *GNU/Linux* distros
  - Or install the latest FUSE manually from [source][fuse]

Compile:

    make

**Note:** If your FUSE installation is in a non-default location you may have to
export `PKG_CONFIG_PATH` before compiling.

Usage
-----

To mount a `.sparsebundle` disk image, execute the following command:

    sparsebundlefs [-o options] sparsebundle mountpoint

For example:

    sparsebundlefs ~/MyDiskImage.sparsebundle /tmp/my-disk-image

This will give you a directory at the mount point with a single `sparsebundle.dmg` file.

You may then proceed to mount the `.dmg` file using regular means, *eg.*:

    mount -o loop -t hfsplus /tmp/my-disk-image/sparsebundle.dmg /mnt/my-disk

This will give you read-only access to the content of the sparse-bundle disk image.

License
-------

This software is licensed under the [BSD two-clause "simplified" license][bsd].



[osxfuse]: http://osxfuse.github.com/ "Fuse for OSX"
[fuse]: http://fuse.sourceforge.net/ "FUSE"
[bsd]: http://opensource.org/licenses/BSD-2-Clause "BSD two-clause license"