#
#  Usage: make [target] [platform|alias|all], e.g.:
#
#   $ make clean all - cleans all available platforms
#   $ make gcc - builds on all available GCC platforms
#   $ make check 32 - run tests on all 32-bit platforms
#
#  Copyright (c) 2018 Tor Arne Vestbø
#
#  Permission is hereby granted, free of charge, to any person obtaining a copy
#  of this software and associated documentation files (the "Software"), to deal
#  in the Software without restriction, including without limitation the rights
#  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#  copies of the Software, and to permit persons to whom the Software is
#  furnished to do so, subject to the following conditions:
#
#  The above copyright notice and this permission notice shall be included in all
#  copies or substantial portions of the Software.
#
#  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
#  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
#  MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
#  IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
#  DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
#  OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE
#  OR OTHER DEALINGS IN THE SOFTWARE.
#
# ------------ Platform selection ------------

AVAILABLE_PLATFORMS := macos-clang-64 linux-gcc-32 linux-gcc-64

OS := $(shell uname -s)
ARCH ?= $(shell uname -m)

ifeq ($(OS),Darwin)
    NATIVE_PLATFORM=macos-clang-64
else ifeq ($(OS),Linux)
  ifeq ($(ARCH),x86_64)
	NATIVE_PLATFORM=linux-gcc-64
  else
	NATIVE_PLATFORM=linux-gcc-32
  endif
endif

ACTUAL_GOALS := $(MAKECMDGOALS)
ifneq ($(filter all,$(MAKECMDGOALS)),)
    PLATFORMS := $(AVAILABLE_PLATFORMS)
    ACTUAL_GOALS := $(filter-out all,$(ACTUAL_GOALS))
    all: ; @:
endif

define expand_platform_alias
  ifneq ($(filter $(alias),$(MAKECMDGOALS)),)
    PLATFORMS += $(platform)
    ACTUAL_GOALS := $(filter-out $(alias),$(ACTUAL_GOALS))
    $(alias):: $$(PLATFORMS) ; @:
  endif
endef

define detect_platform
  ifneq ($(filter $(platform),$(MAKECMDGOALS)),)
    PLATFORMS += $(platform)
    ACTUAL_GOALS := $(filter-out $(platform),$(ACTUAL_GOALS))
  endif
  $(foreach alias,$(subst -, ,$(platform)), $(eval $(expand_platform_alias)))
endef

$(foreach platform,$(AVAILABLE_PLATFORMS), $(eval $(detect_platform)))
PLATFORMS := $(strip $(sort $(subst $(COMMA), ,$(PLATFORMS))))
ifeq ($(PLATFORMS),)
    PLATFORMS := $(NATIVE_PLATFORM)
endif

COMMA := ,
MFLAGS := $(filter-out --jobserver-fds%,$(MFLAGS))
make_noop = $(eval $$($1): % : ; @:)
ensure_binary = $(if $(shell which $1),,\
	$(error Could not find '$(strip $1)' binary))

# Note: Doesn't work for paths with spaces in them
SRC_DIR=$(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

# ------------ Multiple platforms ------------

ifeq ($(shell expr $(words $(PLATFORMS)) \> 1), 1)

%:: $(PLATFORMS) ;
$(PLATFORMS):
	@$(MAKE) -f $(MAKEFILE_LIST) $(MFLAGS) \
		$(filter-out $(NATIVE_PLATFORM),$@) $(ACTUAL_GOALS)

$(call make_noop,ACTUAL_GOALS)

# ------------ Single non-native platform ------------

else ifneq ($(NATIVE_PLATFORM),$(PLATFORMS))

linux-gcc-%: docker ;
docker:
	$(call ensure_binary,docker-compose)
	@docker-compose -f $(SRC_DIR)/docker-compose.yaml run --rm \
		$(PLATFORMS) $(MFLAGS) $(ACTUAL_GOALS) DEBUG=$(DEBUG); \
	stty sane # Work around docker-compose messing up the terminal

$(call make_noop,ACTUAL_GOALS)

%::
	$(error "No way to build for $(PLATFORMS) on $(NATIVE_PLATFORM))

# ------------ Native platform ------------

else

TARGET = sparsebundlefs
.DEFAULT_GOAL := $(TARGET)

$(call make_noop,NATIVE_PLATFORM)

ifeq ($(strip $(ACTUAL_GOALS)),)
    ACTUAL_GOALS := $(.DEFAULT_GOAL)
    $(NATIVE_PLATFORM): $(ACTUAL_GOALS)
endif

vpath %.cpp $(SRC_DIR)/src

PKG_CONFIG = pkg-config
$(call ensure_binary,$(PKG_CONFIG))

override CFLAGS += -std=c++11 -Wall -Wextra -pedantic -O2 -g

ifeq ($(ARCH),i386)
  ARCH_FLAGS := -m32
endif

DEFINES = -DFUSE_USE_VERSION=26

ifeq ($(OS),Darwin)
    # Pick up macFUSE, even with pkg-config from MacPorts
    PKG_CONFIG := PKG_CONFIG_PATH=/usr/local/lib/pkgconfig $(PKG_CONFIG)
else ifeq ($(OS),Linux)
    LDFLAGS += -Wl,-rpath=$(shell $(PKG_CONFIG) fuse --variable=libdir)
endif

FUSE_CFLAGS := $(shell $(PKG_CONFIG) fuse --cflags)
FUSE_LDFLAGS := $(shell $(PKG_CONFIG) fuse --libs)

%.o: %.cpp
	$(CXX) -c $< -o $@ $(CFLAGS) $(ARCH_FLAGS) $(FUSE_CFLAGS) $(DEFINES)

$(TARGET): sparsebundlefs.o
	$(CXX) $< -o $@ $(LDFLAGS) $(ARCH_FLAGS) $(FUSE_LDFLAGS)

HFSFUSE_DIR := $(SRC_DIR)/src/3rdparty/hfsfuse
HFSFUSE_DEPS := $(shell find $(HFSFUSE_DIR))
export HFSFUSE_DIR

hfsfuse: $(HFSFUSE_DEPS)
	$(if $(wildcard $(HFSFUSE_DIR)/.git),,$(error Please init and update git submodules))
	$(call ensure_binary,git)
	@printf "Building hfsfuse... \n"
	@tmpdir=$$(mktemp -d); GIT_DIR=$(HFSFUSE_DIR)/.git GIT_WORK_TREE=$$tmpdir git checkout . \
		&& GIT_DIR=$(HFSFUSE_DIR)/.git make -C $$tmpdir CONFIG_CFLAGS="$(ARCH_FLAGS) -D_FILE_OFFSET_BITS=64" LDFLAGS=$(ARCH_FLAGS) >/dev/null \
		&& cp $$tmpdir/hfsfuse $(CURDIR) && cp $$tmpdir/hfsdump $(CURDIR) \
		&& printf "OK\n" && rm -Rf $$tmpdir

TESTS_DIR=$(SRC_DIR)/tests
TESTDATA_DIR := $(TESTS_DIR)/data
$(TESTDATA_DIR):
	@mkdir $(TESTDATA_DIR)

TEST_BUNDLE := $(TESTDATA_DIR)/basic.sparsebundle
export TEST_BUNDLE

$(TEST_BUNDLE): $(TESTDATA_DIR) $(HFSFUSE_DEPS)
	$(call ensure_binary,hdiutil)
	@test ! -e $@ || rm -Rf $@
	@printf "Creating testdata..." \
		&& hdiutil create -size 1TB -format SPARSEBUNDLE -layout NONE \
			-fs HFS+ -srcfolder $(HFSFUSE_DIR) $@

test_%: check ; @:
check_%: check ; @:
check: $(TARGET) $(TEST_BUNDLE) hfsfuse
	@echo "============== $(PLATFORMS) =============="
	@PATH="$(CURDIR):$(PATH)" $(SRC_DIR)/tests/testrunner.sh $(TESTS_DIR)/*.tst \
		$(subst check_,test_,$(filter check_%,$(ACTUAL_GOALS))) $(filter test_%,$(ACTUAL_GOALS))

clean:
	rm -f $(TARGET)
	rm -Rf $(TARGET).dSYM
	rm -f hfsfuse hfsdump
	rm -f *.o

distclean: clean
	rm -Rf $(TESTDATA_DIR)

# Install

prefix = /usr/local

.PHONY: install
install: sparsebundlefs
	install -d "$(DESTDIR)$(prefix)/bin"
	install -m 755 sparsebundlefs "$(DESTDIR)$(prefix)/bin/"

.PHONY: uninstall
uninstall:
	rm -f $(DESTDIR)$(prefix)/bin/sparsebundlefs

endif
