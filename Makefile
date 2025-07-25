BUILDDIR=$(shell pwd)/build
OUTPUTDIR=$(shell pwd)/output

define rootfs
	mkdir -vp $(BUILDDIR)/alpm-hooks/usr/share/libalpm/hooks
	find /usr/share/libalpm/hooks -exec ln -sf /dev/null $(BUILDDIR)/alpm-hooks{} \;

	mkdir -vp $(BUILDDIR)/var/lib/pacman/ $(OUTPUTDIR)
	install -Dm644 /usr/share/devtools/pacman.conf.d/extra.conf $(BUILDDIR)/etc/pacman.conf
	cat pacman-conf.d-berserkarch.conf >> $(BUILDDIR)/etc/pacman.conf

	sed -i 's/#DisableSandbox/DisableSandbox/' "${BUILDDIR}/etc/pacman.conf"

	sed 's/Include = /&rootfs/g' < $(BUILDDIR)/etc/pacman.conf > pacman.conf
	cp --recursive --preserve=timestamps --backup --suffix=.pacnew rootfs/* $(BUILDDIR)/

	fakechroot -- fakeroot -- pacman -Sy -r $(BUILDDIR) \
		--noconfirm --dbpath $(BUILDDIR)/var/lib/pacman \
		--config pacman.conf \
		--noscriptlet \
		--hookdir $(BUILDDIR)/alpm-hooks/usr/share/libalpm/hooks/ $(2)

  fakechroot -- fakeroot -- chroot $(BUILDDIR) update-ca-trust
	fakechroot -- fakeroot -- chroot $(BUILDDIR) locale-gen
	fakechroot -- fakeroot -- chroot $(BUILDDIR) sh -c 'pacman-key --init && pacman-key --populate && bash -c "rm -rf etc/pacman.d/gnupg/{openpgp-revocs.d/,private-keys-v1.d/,pubring.gpg~,gnupg.S.}*"'
  echo 'allow-weak-key-signatures' >> $(BUILDDIR)/etc/pacman.d/gnupg/gpg.conf

	# add system users
	fakechroot -- fakeroot -- chroot $(BUILDDIR) /usr/bin/systemd-sysusers --root "/"

	# remove passwordless login for root (see CVE-2019-5021 for reference)
	sed -i -e 's/^root::/root:!:/' "$(BUILDDIR)/etc/shadow"

	# Use BlackArch shell configs and os-release
	fakechroot -- fakeroot -- chroot $(BUILDDIR) cp /etc/skel/{.bashrc,.zshrc,.bash_profile} /root/

	# fakeroot to map the gid/uid of the builder process to root
	fakeroot -- tar --numeric-owner --xattrs --acls --exclude-from=exclude -C $(BUILDDIR) -c . -f $(OUTPUTDIR)/$(1).tar

	cd $(OUTPUTDIR); zstd --long -T0 -8 $(1).tar; sha256sum $(1).tar.zst > $(1).tar.zst.SHA256
endef

define dockerfile
	sed -e "s|TEMPLATE_ROOTFS_FILE|$(1).tar.zst|" \
	    Dockerfile.template > $(OUTPUTDIR)/Dockerfile.$(1)
endef

.PHONY: clean
clean:
	rm -rf $(BUILDDIR) $(OUTPUTDIR)

$(OUTPUTDIR)/berserkarch-base.tar.xz:
	$(call rootfs,berserkarch-base,base berserk-keyring blackarch-keyring chaotic-keyring berserk-hooks)

$(OUTPUTDIR)/berserkarch-base-devel.tar.xz:
	$(call rootfs,berserkarch-base-devel,base base-devel berserk-keyring blackarch-keyring chaotic-keyring vim edk2-shell grub git archiso berserk-hooks)

$(OUTPUTDIR)/Dockerfile.base: $(OUTPUTDIR)/berserkarch-base.tar.xz
	$(call dockerfile,berserkarch-base)

$(OUTPUTDIR)/Dockerfile.base-devel: $(OUTPUTDIR)/berserkarch-base-devel.tar.xz
	$(call dockerfile,berserkarch-base-devel)

.PHONY: docker-berserkarch-base
berserkarch-base: $(OUTPUTDIR)/Dockerfile.base
	docker build -f $(OUTPUTDIR)/Dockerfile.berserkarch-base -t berserkarch/berserkarch:base $(OUTPUTDIR)

.PHONY: docker-berserkarch-base-devel
berserkarch-base-devel: $(OUTPUTDIR)/Dockerfile.base-devel
	docker build -f $(OUTPUTDIR)/Dockerfile.berserkarch-base-devel -t berserkarch/berserkarch:base-devel $(OUTPUTDIR)
