# BerserkArch Official Docker Images

- Website: [https://berserkarch.xyz](https://berserkarch.xyz)
- Wiki: [https://wiki.berserkarch.xyz](https://wiki.berserkarch.xyz)

### Special note about the novnc image

You need to run the container with the `--security-opt seccomp=unconfined` options, otherwise, it will fail. See https://gitlab.xfce.org/apps/xfce4-terminal/-/issues/116 and https://github.com/mviereck/x11docker/issues/346 for details.

## Availability

Root filesystem tarballs are provided by Github Actions and are **only** available for 1 week once the new build is triggered.

## Setup Dependencies

- Install following deps (For Arch)

```bash
sudo pacman -Syy arch-install-scripts devtools fakechroot fakeroot
```

## Updating

Berserk Arch is a rolling release distribution, so a full update is recommended when installing new packages. In other words, we suggest either execute RUN `pacman -Syu` immediately after your FROM statement or as soon as you docker run into a container.

## Commands

### Clone the Repo

### Building Images

- Base Image

```bash
make && make berserkarch-base
```

- Offsec Image

```bash
make && make berserkarch-offsec
```

- Base Dev Image

```bash
make && make berserkarch-base-devel
```

- Base Image with VNC

```bash
docker build ./berserk-novnc --file ./berserk-novnc/Dockerfile --tag docker.io/berserkarch/berserkarch:novnc
```

### Running the Images

- Base image

```bash
docker run -it --rm \
    --security-opt seccomp=unconfined \
    --privileged \
    --name berserkarch \
    --hostname berserk \
    berserkarch/berserkarch:base
```

- Offsec Image

```bash
docker run -it --rm \
    --security-opt seccomp=unconfined \
    --privileged
    --name berserkarch \
    --hostname berserk \
    --user user \
    -w /home/user \
    berserkarch/berserkarch:offsec
```

- Base Dev Image (Root)

```bash
docker run -it --rm \
    --security-opt seccomp=unconfined \
    --privileged
    --name berserkarch \
    --hostname berserk \
    berserkarch/berserkarch:base-devel
```

- Base Image with VNC

```bash
docker run -it --rm \
    --security-opt seccomp=unconfined \
    --hostname berserk \
    --name berserkarch \
    --privileged \
    -p 5901:5901 \
    -p 6080:6080 \
    -p 2222:22 \
    -p 8080:8080 \
    berserkarch/berserkarch:novnc
```

### Building the ISO

```bash
docker run -it --rm \
  --security-opt seccomp=unconfined \
  --privileged \
  --name berserkarch \
  --hostname berserk \
  -v $(pwd)/berserk-build:/berserkarch/ \
  berserkarch/berserkarch:base-devel \
  bash -c "git clone https://gitlab.com/berserkarch/iso-profiles/berserkarch.git && cd berserkarch && make devbuild"
```
