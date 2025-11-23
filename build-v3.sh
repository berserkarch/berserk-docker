#!/bin/bash
set -euo pipefail

BUILDDIR="$(pwd)/build"
OUTPUTDIR="$(pwd)/output"
DEBIANDIR="$(pwd)/debian-rootfs"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Metadata
BUILD_DATE=$(date -u +"%Y.%m.%d")
PROJECT_URL="https://berserkarch.xyz"
RELEASE_DESCRIPTION="$BUILD_DATE-$PROJECT_URL"
IMAGE_NAME="berserkdeb"
ARCHITECTURE="amd64"
TARBALL="${IMAGE_NAME}-${ARCHITECTURE}.tar.gz"

log_info() {
        echo -e "${GREEN}[INFO]${NC} $*"
}

log_error() {
        echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_warn() {
        echo -e "${YELLOW}[WARN]${NC} $*"
}

# Helper function for chroot operations in debian rootfs
rootfs_chroot() {
        local rootfsDir="$1"
        shift
        PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
                chroot "$rootfsDir" "$@"
}

# Function to build Debian rootfs tarball
build_debian_rootfs() {
        local debian_mirror="https://deb.debian.org/debian"
        local distro="trixie"
        local rootfsDir="${DEBIANDIR}/rootfs-${IMAGE_NAME}-${ARCHITECTURE}"

        log_info "=== Building Debian rootfs tarball ==="

        # Validation checks
        if [ ! -e /usr/share/debootstrap/scripts/"$distro" ]; then
                log_error "debootstrap has no script for $distro - install newer debootstrap"
                return 1
        fi

        # Clean previous builds
        rm -rf "$rootfsDir" "$TARBALL" "${DEBIANDIR}"
        mkdir -p "${DEBIANDIR}"

        log_info "Running debootstrap for Debian $distro ($ARCHITECTURE)"
        local ret=0
        debootstrap --variant=minbase --components=main,contrib,non-free,non-free-firmware \
                --arch="$ARCHITECTURE" --include=debian-archive-keyring \
                "$distro" "$rootfsDir" "$debian_mirror" || ret=$?

        if [ $ret != 0 ]; then
                log_error "debootstrap failed with exit code $ret"
                [ -e "$rootfsDir"/debootstrap/debootstrap.log ] &&
                        tail -v "$rootfsDir"/debootstrap/debootstrap.log
                return $ret
        fi

        # Add Kali repositories
        log_info "Configuring Kali repositories"
        cat >"$rootfsDir/etc/apt/sources.list.d/kali.list" <<EOF
deb http://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware
deb http://http.kali.org/kali kali-bleeding-edge main contrib non-free non-free-firmware
deb http://http.kali.org/kali kali-experimental main contrib non-free non-free-firmware
EOF

        # Download and install Kali archive keyring
        log_info "Installing Kali archive keyring"
        local KEYRING_PKG_PATH=$(wget -nv -O - \
                https://kali.download/kali/dists/kali-rolling/main/binary-amd64/Packages.gz |
                gzip -dc | grep ^Filename: | grep kali-archive-keyring | head -n 1 | awk '{print $2}')
        local KEYRING_PKG_URL="https://kali.download/kali/$KEYRING_PKG_PATH"

        wget -nv "$KEYRING_PKG_URL" -O "${DEBIANDIR}/kali-archive-keyring.deb"
        sha256sum "${DEBIANDIR}/kali-archive-keyring.deb"
        cp "${DEBIANDIR}/kali-archive-keyring.deb" "$rootfsDir/tmp/"

        rootfs_chroot "$rootfsDir" sh -c 'find /tmp -maxdepth 1 -name "kali-archive-keyring*.deb" -exec dpkg -i {} \;'
        rootfs_chroot "$rootfsDir" sh -c 'find /tmp -maxdepth 1 -name "kali-archive-keyring*.deb" -exec rm {} \;'
        rm "${DEBIANDIR}/kali-archive-keyring.deb"

        # Update and install kali-defaults
        log_info "Installing Kali defaults"
        rootfs_chroot "$rootfsDir" apt update -y
        rootfs_chroot "$rootfsDir" apt-get -y --no-install-recommends install kali-defaults
        rootfs_chroot "$rootfsDir" apt-get clean

        # Docker-specific optimizations
        log_info "Applying Docker optimizations"

        # Prevent services from starting during package installation
        cat >"$rootfsDir/usr/sbin/policy-rc.d" <<-'EOF'
#!/bin/sh
exit 101
EOF
        chmod +x "$rootfsDir/usr/sbin/policy-rc.d"

        # Speed up dpkg
        echo 'force-unsafe-io' >"$rootfsDir/etc/dpkg/dpkg.cfg.d/docker-apt-speedup"

        # Configure APT for Docker
        local aptGetClean='"rm -f /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/*.deb /var/cache/apt/*.bin || true";'
        cat >"$rootfsDir/etc/apt/apt.conf.d/docker-clean" <<-EOF
DPkg::Post-Invoke { ${aptGetClean} };
Dir::Cache::pkgcache "";
Dir::Cache::srcpkgcache "";
EOF

        echo 'Acquire::Languages "none";' >"$rootfsDir/etc/apt/apt.conf.d/docker-no-languages"

        cat >"$rootfsDir/etc/apt/apt.conf.d/docker-gzip-indexes" <<-'EOF'
Acquire::GzipIndexes "true";
Acquire::CompressionTypes::Order:: "gz";
EOF

        echo 'Apt::AutoRemove::SuggestsImportant "false";' >"$rootfsDir/etc/apt/apt.conf.d/docker-autoremove-suggests"

        # Cleanup
        log_info "Cleaning up rootfs"
        rm -f "$rootfsDir/var/cache/ldconfig/aux-cache"
        rm -rf "$rootfsDir/var/lib/apt/lists"/*
        mkdir -p "$rootfsDir/var/lib/apt/lists/partial"
        find "$rootfsDir/var/log" -depth -type f -print0 | xargs -0 truncate -s 0
        rmdir "$rootfsDir/run/mount" 2>/dev/null || true

        # Create tarball
        log_info "Creating Debian rootfs tarball: $TARBALL"
        tar -C "$rootfsDir" --exclude "./dev/**" -pczf "$TARBALL" .

        log_info "Debian rootfs tarball created successfully: $TARBALL"
        log_info "Tarball size: $(du -h "$TARBALL" | cut -f1)"
}

# Function to build rootfs
build_rootfs() {
        local name="$1"
        local packages="$2"
        local with_user="${3:-}"

        log_info "Building rootfs for: $name"

        # Setup alpm hooks - Fixed the find command
        mkdir -vp "${BUILDDIR}/alpm-hooks/usr/share/libalpm/hooks"
        if [ -d "/usr/share/libalpm/hooks" ]; then
                find /usr/share/libalpm/hooks -type f -exec sh -c 'ln -sf /dev/null "${BUILDDIR}/alpm-hooks$(echo {} | sed "s|/usr/share/libalpm/hooks||")"' \; 2>/dev/null || true
        fi

        # Setup pacman directories
        mkdir -vp "${BUILDDIR}/var/lib/pacman/" "${OUTPUTDIR}"
        install -Dm644 /usr/share/devtools/pacman.conf.d/extra.conf "${BUILDDIR}/etc/pacman.conf"
        cat pacman-conf.d-berserkarch.conf >>"${BUILDDIR}/etc/pacman.conf"

        # Disable sandbox
        sed -i 's/#DisableSandbox/DisableSandbox/' "${BUILDDIR}/etc/pacman.conf"

        # Modify pacman.conf for rootfs
        sed 's|Include = |&rootfs|g' <"${BUILDDIR}/etc/pacman.conf" >pacman.conf
        cp --recursive --preserve=timestamps --backup --suffix=.pacnew rootfs/* "${BUILDDIR}/" 2>/dev/null || log_warn "No rootfs directory found, skipping"

        # Install packages
        log_info "Installing packages: $packages"
        fakechroot -- fakeroot -- pacman -Sy -r "${BUILDDIR}" \
                --noconfirm --dbpath "${BUILDDIR}/var/lib/pacman" \
                --config pacman.conf \
                --noscriptlet \
                --hookdir "${BUILDDIR}/alpm-hooks/usr/share/libalpm/hooks/" $packages

        # Update CA trust and locale
        log_info "Updating CA trust and generating locale"
        fakechroot -- fakeroot -- chroot "${BUILDDIR}" update-ca-trust
        fakechroot -- fakeroot -- chroot "${BUILDDIR}" locale-gen

        # Initialize pacman keys
        log_info "Initializing pacman keyring"
        fakechroot -- fakeroot -- chroot "${BUILDDIR}" sh -c 'pacman-key --init && pacman-key --populate && bash -c "rm -rf etc/pacman.d/gnupg/{openpgp-revocs.d/,private-keys-v1.d/,pubring.gpg~,gnupg.S.}*"'
        echo 'allow-weak-key-signatures' >>"${BUILDDIR}/etc/pacman.d/gnupg/gpg.conf"

        # Add system users
        log_info "Adding system users"
        fakechroot -- fakeroot -- chroot "${BUILDDIR}" /usr/bin/systemd-sysusers --root "/"

        # Copy shell configs - Fixed to check if files exist first
        log_info "Copying shell configurations"
        if [ -f "${BUILDDIR}/etc/skel/.bashrc" ]; then
                fakechroot -- fakeroot -- chroot "${BUILDDIR}" cp /etc/skel/.bashrc /root/ 2>/dev/null || true
        fi
        if [ -f "${BUILDDIR}/etc/skel/.zshrc" ]; then
                fakechroot -- fakeroot -- chroot "${BUILDDIR}" cp /etc/skel/.zshrc /root/ 2>/dev/null || true
        fi
        if [ -f "${BUILDDIR}/etc/skel/.bash_profile" ]; then
                fakechroot -- fakeroot -- chroot "${BUILDDIR}" cp /etc/skel/.bash_profile /root/ 2>/dev/null || true
        fi

        # Create user if requested
        if [ "$with_user" = "withuser" ]; then
                log_info "Setting up Oh My Zsh and creating user account"

                # Remove zsh configs before installing oh-my-zsh
                rm -f "${BUILDDIR}/etc/skel/.zshrc"
                rm -f "${BUILDDIR}/root/.zshrc"

                # Install berserkarch-omz package
                log_info "Installing berserkarch-omz package"
                fakechroot -- fakeroot -- pacman -Sy -r "${BUILDDIR}" \
                        --noconfirm --dbpath "${BUILDDIR}/var/lib/pacman" \
                        --config pacman.conf \
                        --noscriptlet \
                        --hookdir "${BUILDDIR}/alpm-hooks/usr/share/libalpm/hooks/" berserkarch-omz

                # Copy oh-my-zsh configs to root
                echo "export TERM=xterm-256color" >>"${BUILDDIR}/etc/skel/.zshrc"
                if [ -d "${BUILDDIR}/etc/skel/.oh-my-zsh" ]; then
                        cp -r "${BUILDDIR}/etc/skel/.oh-my-zsh" "${BUILDDIR}/root/"
                fi
                if [ -f "${BUILDDIR}/etc/skel/.zshrc" ]; then
                        cp "${BUILDDIR}/etc/skel/.zshrc" "${BUILDDIR}/root/"
                fi

                # Create user account
                log_info "Creating user account with passwordless sudo"
                fakechroot -- fakeroot -- chroot "${BUILDDIR}" useradd -m -u 1000 -G wheel -s /bin/zsh user
                fakechroot -- fakeroot -- chroot "${BUILDDIR}" sh -c 'echo "user:password" | chpasswd'

                # Setup sudo for wheel group
                mkdir -p "${BUILDDIR}/etc/sudoers.d"
                echo "%wheel ALL=(ALL:ALL) NOPASSWD:ALL" >"${BUILDDIR}/etc/sudoers.d/wheel"
                chmod 440 "${BUILDDIR}/etc/sudoers.d/wheel"
        fi

        # Disable passwordless root login (CVE-2019-5021)
        log_info "Securing root account"
        sed -i -e 's/^root::/root:!:/' "${BUILDDIR}/etc/shadow"

        # Create tarball - Fixed to check if exclude file exists
        log_info "Creating compressed tarball"
        if [ -f exclude ]; then
                fakeroot -- tar --numeric-owner --xattrs --acls --exclude-from=exclude -C "${BUILDDIR}" -c . -f "${OUTPUTDIR}/${name}.tar"
        else
                log_warn "exclude file not found, creating tarball without exclusions"
                fakeroot -- tar --numeric-owner --xattrs --acls -C "${BUILDDIR}" -c . -f "${OUTPUTDIR}/${name}.tar"
        fi
        cd "${OUTPUTDIR}"
        zstd --long -T0 -8 "${name}.tar"
        sha256sum "${name}.tar.zst" >"${name}.tar.zst.SHA256"
        cd - >/dev/null

        log_info "Rootfs build complete: ${OUTPUTDIR}/${name}.tar.zst"
}

# Function to generate Dockerfile
generate_dockerfile() {
        local name="$1"
        log_info "Generating Dockerfile for: $name"

        if [ ! -f Dockerfile.template ]; then
                log_error "Dockerfile.template not found"
                return 1
        fi

        sed -e "s|TEMPLATE_ROOTFS_FILE|${name}.tar.zst|" \
                Dockerfile.template >"${OUTPUTDIR}/Dockerfile.${name}"
}

# Function to build Docker image
build_docker_image() {
        local name="$1"
        local tag="$2"
        log_info "Building Docker image: $tag"

        if [ ! -f "${OUTPUTDIR}/Dockerfile.${name}" ]; then
                log_error "Dockerfile not found: ${OUTPUTDIR}/Dockerfile.${name}"
                return 1
        fi

        docker build -f "${OUTPUTDIR}/Dockerfile.${name}" \
                --build-arg TARBALL="$TARBALL" \
                --build-arg BUILD_DATE="$BUILD_DATE" \
                --build-arg PROJECT_URL="$PROJECT_URL" \
                --build-arg RELEASE_DESCRIPTION="$RELEASE_DESCRIPTION" \
                -t "$tag" \
                "${OUTPUTDIR}"
}

# Clean build artifacts
clean() {
        log_warn "Cleaning build and output directories"
        rm -rf "${BUILDDIR}" "${OUTPUTDIR}" "${DEBIANDIR}" "$TARBALL"
        log_info "Clean complete"
}

# Build berserkarch-base
build_base() {
        log_info "=== Building berserkarch-base ==="
        rm -rf "${BUILDDIR}"
        build_rootfs "berserkarch-base" "base berserk-keyring blackarch-keyring chaotic-keyring berserk-hooks" ""
        generate_dockerfile "berserkarch-base"
        build_docker_image "berserkarch-base" "berserkarch/berserkarch:base"
}

# Build berserkarch-offsec
build_offsec() {
        log_info "=== Building berserkarch-offsec ==="
        rm -rf "${BUILDDIR}"
        build_rootfs "berserkarch-offsec" \
                "base berserk-keyring blackarch-keyring chaotic-keyring berserk-hooks sudo ca-certificates curl git lsb-release nano vim wget jq htop dnsutils nmap python python-pip python-pipx unzip whois go berserk-neofetch exa which neovim gcc make berserk-lazyvim fd fzf ripgrep" \
                "withuser"
        generate_dockerfile "berserkarch-offsec"
        build_docker_image "berserkarch-offsec" "berserkarch/berserkarch:offsec"
}

# Build berserkarch-base-devel
build_base_devel() {
        log_info "=== Building berserkarch-base-devel ==="
        rm -rf "${BUILDDIR}"
        build_rootfs "berserkarch-base-devel" \
                "base base-devel berserk-keyring blackarch-keyring chaotic-keyring vim edk2-shell grub git archiso berserk-hooks berserk-dev-tools" \
                ""
        generate_dockerfile "berserkarch-base-devel"
        build_docker_image "berserkarch-base-devel" "berserkarch/berserkarch:base-devel"
}

# Build berserkarch-deb (debian edition)
build_deb_edition() {
        log_info "=== Building berserkarch-deb (debian) ==="

        # Build the Debian rootfs tarball first
        build_debian_rootfs || {
                log_error "Failed to build Debian rootfs"
                return 1
        }

        # Clean and setup output directory
        rm -rf "${BUILDDIR}"
        mkdir -p "${OUTPUTDIR}"

        if [ ! -f Dockerfile.berserkarch-deb ]; then
                log_error "Dockerfile.berserkarch-deb not found"
                return 1
        fi

        if [ ! -f "$TARBALL" ]; then
                log_error "Debian tarball not found: $TARBALL"
                return 1
        fi

        # Copy both Dockerfile and tarball to output directory
        log_info "Copying build artifacts to output directory"
        cp Dockerfile.berserkarch-deb "${OUTPUTDIR}/"
        cp "$TARBALL" "${OUTPUTDIR}/"

        build_docker_image "berserkarch-deb" "berserkarch/berserkarch:deb"
}

# Build all targets
build_all() {
        build_base
        build_offsec
        build_base_devel
        build_deb_edition
}

# Show usage
usage() {
        cat <<EOF
Usage: $0 [COMMAND]

Commands:
    base         Build berserkarch-base image
    offsec       Build berserkarch-offsec image
    base-devel   Build berserkarch-base-devel image
    deb          Build berserkarch-deb image (includes Debian rootfs generation)
    deb-rootfs   Build only the Debian rootfs tarball
    all          Build all images
    clean        Remove build and output directories
    help         Show this help message

Examples:
    $0 base          # Build only base image
    $0 deb-rootfs    # Generate only Debian rootfs tarball
    $0 deb           # Build Debian rootfs and Docker image
    $0 all           # Build all images
    $0 clean         # Clean all build artifacts

EOF
}

# Main script logic
main() {
        if [ $# -eq 0 ]; then
                log_error "No command specified"
                usage
                exit 1
        fi

        case "$1" in
        base)
                build_base
                ;;
        offsec)
                build_offsec
                ;;
        base-devel)
                build_base_devel
                ;;
        deb-rootfs)
                build_debian_rootfs
                ;;
        deb)
                build_deb_edition
                ;;
        all)
                build_all
                ;;
        clean)
                clean
                ;;
        help | --help | -h)
                usage
                ;;
        *)
                log_error "Unknown command: $1"
                usage
                exit 1
                ;;
        esac
}

main "$@"
