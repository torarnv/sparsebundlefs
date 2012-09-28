TARGET = sparsebundlefs

PKG_CONFIG = pkg-config
CFLAGS = -Wall -O3

ifeq ($(shell uname), Darwin)
	# Pick up OSXFUSE, even with pkg-config from MacPorts
	PKG_CONFIG := PKG_CONFIG_PATH=/usr/local/lib/pkgconfig $(PKG_CONFIG)
	DEFINES = -DFUSE_USE_VERSION=26
endif

FUSE_FLAGS := $(shell $(PKG_CONFIG) fuse --cflags --libs)

$(TARGET): sparsebundlefs.cpp
	$(CXX) $(CFLAGS) $(FUSE_FLAGS) $(DEFINES) $< -o $@

all: $(TARGET)

clean:
	rm -f $(TARGET)
