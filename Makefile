include config.mk

# get main- and subtarget name from TARGET
MAINTARGET=$(word 1, $(subst _, ,$(TARGET)))
SUBTARGET=$(word 2, $(subst _, ,$(TARGET)))

GIT_REPO=git config --get remote.origin.url
GIT_BRANCH=git symbolic-ref HEAD | sed -e 's,.*/\(.*\),\1,'
REVISION=git describe --always

ifeq ($(filter openwrt lede,$(MBEDFW_TYPE)),)
 $(error invalid FIRMWARE-TYPE "$(MBEDFW_TYPE)")
endif
ifeq ($(MBEDFW_TYPE),openwrt)
 MBEDFW_DIR=$(FW_DIR)/openwrt
 MBEDFW_SRC=$(OPENWRT_SRC)
 MBEDFW_COMMIT=$(OPENWRT_COMMIT)
else ifeq ($(MBEDFW_TYPE),lede)
 MBEDFW_DIR=$(FW_DIR)/lede
 MBEDFW_SRC=$(LEDE_SRC)
 MBEDFW_COMMIT=$(LEDE_COMMIT)
else
 $(error invalid FIRMWARE-TYPE "$(MBEDFW_TYPE)")
endif
$(info building for $(MBEDFW_TYPE))

# set dir and file names
FW_DIR=$(shell pwd)
TARGET_CONFIG=$(FW_DIR)/configs/common.config $(FW_DIR)/configs/$(MAINTARGET)_$(SUBTARGET).config
IB_BUILD_DIR=$(FW_DIR)/imgbldr_tmp
FW_TARGET_DIR=$(FW_DIR)/firmwares/$(MAINTARGET)_$(SUBTARGET)
UMASK=umask 022

# if any of the following files have been changed: clean up openwrt dir
DEPS=$(TARGET_CONFIG) feeds.conf patches $(wildcard patches/*)

# profiles to be built (router models)
PROFILES=$(shell cat $(FW_DIR)/profiles/$(MAINTARGET)_$(SUBTARGET).profiles)

FW_REVISION=$(shell $(REVISION))

default: firmwares

# clone openwrt
$(MBEDFW_DIR):
	git clone $(MBEDFW_SRC) $(MBEDFW_DIR)

# clean up firmware working copy
mbedfw-clean: stamp-clean-mbedfw-cleaned .stamp-mbedfw-cleaned
.stamp-mbedfw-cleaned: config.mk | $(MBEDFW_DIR) mbedfw-clean-bin
	cd $(MBEDFW_DIR); \
	  ./scripts/feeds clean && \
	  git clean -dff && git fetch && git reset --hard HEAD && \
	  rm -rf .config feeds.conf build_dir/target-* logs/
	touch $@

mbedfw-clean-bin:
	rm -rf $(MBEDFW_DIR)/bin
	rm -rf $(MBEDFW_DIR)/build_dir/target-*/*-{imagebuilder,sdk}-*

# update openwrt and checkout specified commit
mbedfw-update: stamp-clean-mbedfw-updated .stamp-mbedfw-updated
.stamp-mbedfw-updated: .stamp-mbedfw-cleaned
	cd $(MBEDFW_DIR); git checkout --detach $(MBEDFW_COMMIT)
	touch $@

# patches require updated openwrt working copy
$(MBEDFW_DIR)/patches: | .stamp-mbedfw-updated
	ln -s $(FW_DIR)/patches $@

# feeds
$(MBEDFW_DIR)/feeds.conf: .stamp-mbedfw-updated feeds.conf
	cp $(FW_DIR)/feeds.conf $@

# update feeds
feeds-update: stamp-clean-feeds-updated .stamp-feeds-updated
.stamp-feeds-updated: $(MBEDFW_DIR)/feeds.conf unpatch
	+cd $(MBEDFW_DIR); \
	  ./scripts/feeds uninstall -a && \
	  ./scripts/feeds update && \
	  ./scripts/feeds install -a
	touch $@

# prepare patch
pre-patch: stamp-clean-pre-patch .stamp-pre-patch
.stamp-pre-patch: .stamp-feeds-updated $(wildcard $(FW_DIR)/patches/*) | $(MBEDFW_DIR)/patches
	touch $@

# patch openwrt working copy
patch: stamp-clean-patched .stamp-patched
.stamp-patched: .stamp-pre-patch
	cd $(MBEDFW_DIR); quilt push -a
	touch $@

.stamp-build_rev: .FORCE
ifneq (,$(wildcard .stamp-build_rev))
ifneq ($(shell cat .stamp-build_rev),$(FW_REVISION))
	echo $(FW_REVISION) | diff >/dev/null -q $@ - || echo -n $(FW_REVISION) >$@
endif
else
	echo -n $(FW_REVISION) >$@
endif

# share download dir
$(FW_DIR)/dl:
	mkdir $(FW_DIR)/dl
$(MBEDFW_DIR)/dl: $(FW_DIR)/dl
	ln -s $(FW_DIR)/dl $(MBEDFW_DIR)/dl

# openwrt config
$(MBEDFW_DIR)/.config: .stamp-patched $(TARGET_CONFIG) .stamp-build_rev $(MBEDFW_DIR)/dl
	cat $(TARGET_CONFIG) >$(MBEDFW_DIR)/.config
	sed -i "/^CONFIG_VERSION_NUMBER=/ s/\"$$/\+$(FW_REVISION)\"/" $(MBEDFW_DIR)/.config
	$(UMASK); \
	  $(MAKE) -C $(MBEDFW_DIR) defconfig

# prepare openwrt working copy
prepare: stamp-clean-prepared .stamp-prepared
.stamp-prepared: .stamp-patched $(MBEDFW_DIR)/.config
	sed -i 's,^# REVISION:=.*,REVISION:=$(FW_REVISION),g' $(MBEDFW_DIR)/include/version.mk
	touch $@

# compile
compile: stamp-clean-compiled .stamp-compiled
.stamp-compiled: .stamp-prepared mbedfw-clean-bin
	$(UMASK); \
	  $(MAKE) -C $(MBEDFW_DIR) $(MAKE_ARGS)
	touch $@

# fill firmwares-directory with:
#  * firmwares built with imagebuilder
#  * imagebuilder file
#  * packages directory
firmwares: stamp-clean-firmwares .stamp-firmwares-build .stamp-firmware-$(MBEDFW_TYPE)-post
.stamp-firmwares-build: .stamp-firmware-$(MBEDFW_TYPE)-pre .stamp-compiled
.stamp-firmwares: .stamp-compiled
	mkdir -p $(FW_TARGET_DIR)
	# Create version info file
	GIT_BRANCH_ESC=$(shell $(GIT_BRANCH) | tr '/' '_'); \
	VERSION_FILE=$(FW_TARGET_DIR)/VERSION.txt; \
	echo "https://github.com/freifunk-berlin/firmware" > $$VERSION_FILE; \
	echo "https://wiki.freifunk.net/Berlin:Firmware" >> $$VERSION_FILE; \
	echo "Firmware: git branch \"$$GIT_BRANCH_ESC\", revision $(FW_REVISION)" >> $$VERSION_FILE; \
	# add openwrt revision with data from config.mk \
	MBEDFW_REVISION=`cd $(MBEDFW_DIR); $(REVISION)`; \
	echo "OpenWRT: repository from $(MBEDFW_SRC), git branch \"$(MBEDFW_COMMIT)\", revision $$MBEDFW_REVISION" >> $$VERSION_FILE; \
	# add feed revisions \
	for FEED in `cd $(MBEDFW_DIR); ./scripts/feeds list -n`; do \
	  FEED_DIR=$(addprefix $(MBEDFW_DIR)/feeds/,$$FEED); \
	  FEED_GIT_REPO=`cd $$FEED_DIR; $(GIT_REPO)`; \
	  FEED_GIT_BRANCH_ESC=`cd $$FEED_DIR; $(GIT_BRANCH) | tr '/' '_'`; \
	  FEED_REVISION=`cd $$FEED_DIR; $(REVISION)`; \
	  echo "Feed $$FEED: repository from $$FEED_GIT_REPO, git branch \"$$FEED_GIT_BRANCH_ESC\", revision $$FEED_REVISION" >> $$VERSION_FILE; \
	done
	./assemble_firmware.sh -p "$(PROFILES)" -i $(IB_FILE) -t $(FW_TARGET_DIR) -u "$(PACKAGES_LIST_DEFAULT)"
	touch $@

.stamp-firmware-openwrt-pre: .stamp-compiled
	rm -rf $(IB_BUILD_DIR)
	mkdir -p $(IB_BUILD_DIR)
	$(eval TOOLCHAIN_PATH := $(shell printf "%s:" $(MBEDFW_DIR)/staging_dir/toolchain-*/bin))
	$(eval IB_FILE := $(shell ls -tr $(MBEDFW_DIR)/bin/$(MAINTARGET)/OpenWrt-ImageBuilder-*.tar.bz2 | tail -n1))
	#mv $(IB_BUILD_DIR)/$(shell basename $(IB_FILE) .tar.bz2) $(IB_BUILD_DIR)/imgbldr
	touch $@

.stamp-firmware-openwrt-post: .stamp-firmwares-build
	# copy imagebuilder, sdk and toolchain (if existing)
	cp -a $(MBEDFW_DIR)/bin/$(MAINTARGET)/OpenWrt-*.tar.bz2 $(FW_TARGET_DIR)/
	mkdir -p $(FW_TARGET_DIR)/packages/targets/$(MAINTARGET)/$(SUBTARGET)
	# copy packages
	PACKAGES_DIR="$(FW_TARGET_DIR)/packages"; \
	rm -rf $$PACKAGES_DIR; \
	cp -a $(MBEDFW_DIR)/bin/$(MAINTARGET)/packages $$PACKAGES_DIR
	rm -rf $(IB_BUILD_DIR)
	touch $@

.stamp-firmware-lede-pre: .stamp-compiled
	rm -rf $(IB_BUILD_DIR)
	mkdir -p $(IB_BUILD_DIR)
	$(eval TOOLCHAIN_PATH := $(shell printf "%s:" $(MBEDFW_DIR)/staging_dir/toolchain-*/bin))
	$(eval IB_FILE := $(shell ls -tr $(MBEDFW_DIR)/bin/targets/$(MAINTARGET)/$(SUBTARGET)/*-imagebuilder-*.tar.xz | tail -n1))
	#mv $(IB_BUILD_DIR)/$(shell basename $(IB_FILE) .tar.bz2) $(IB_BUILD_DIR)/imgbldr
	touch $@

.stamp-firmware-lede-post: .stamp-firmwares-build
	# copy imagebuilder, sdk and toolchain (if existing)
	cp -a $(MBEDFW_DIR)/bin/targets/$(MAINTARGET)/$(SUBTARGET)/*{imagebuilder,sdk}*.tar.xz $(FW_TARGET_DIR)/
	cp -a $(MBEDFW_DIR)/bin/targets/$(MAINTARGET)/$(SUBTARGET)/*toolchain*.tar.bz2 $(FW_TARGET_DIR)/
	mkdir -p $(FW_TARGET_DIR)/packages/targets/$(MAINTARGET)/$(SUBTARGET)/packages
	# copy packages
	PACKAGES_DIR="$(FW_TARGET_DIR)/packages"; \
	rm -rf $$PACKAGES_DIR; \
	cp -a $(MBEDFW_DIR)/bin/$(MAINTARGET)/packages $$PACKAGES_DIR
	rm -rf $(IB_BUILD_DIR)
	touch $@

stamp-clean-%:
	rm -f .stamp-$*

stamp-clean:
	rm -f .stamp-*

# unpatch needs "patches/" in openwrt
unpatch: $(MBEDFW_DIR)/patches
# RC = 2 of quilt --> nothing to be done
	cd $(MBEDFW_DIR); quilt pop -a -f || [ $$? = 2 ] && true
	rm -f .stamp-patched

clean: stamp-clean .stamp-mbedfw-cleaned

.PHONY: mbedfw-clean mbedfw-clean-bin mbedfw-update patch feeds-update prepare compile firmwares stamp-clean clean
.NOTPARALLEL:
.FORCE:
