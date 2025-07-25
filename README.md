# BerserkArch Official Docker Images

### Special note about the novnc image

You need to run the container with the `--security-opt seccomp=unconfined` options, otherwise, it will fail. See https://gitlab.xfce.org/apps/xfce4-terminal/-/issues/116 and https://github.com/mviereck/x11docker/issues/346 for details.

## Availability

Root filesystem tarballs are provided by Github Actions and are **only** available for 1 week once the new build is triggered.

## Updating

Berserk Arch is a rolling release distribution, so a full update is recommended when installing new packages. In other words, we suggest either execute RUN `pacman -Syu` immediately after your FROM statement or as soon as you docker run into a container.

## Commands

### Clone the Repo

### Building Images

```bash
make && make berserkarch-base
```

```bash
make && make berserkarch-base-devel
```

```bash
docker build ./berserk-novnc --file ./berserk-novnc/Dockerfile --tag docker.io/berserkarch/berserkarch:novnc
```

### Running the Images

```bash
docker run -it --security-opt seccomp=unconfined --name barchh --memory 4G --hostname berserk berserkarch/berserkarch:base
```

```bash
docker run -it --rm --security-opt seccomp=unconfined --privileged --name berserk --hostname berserk berserkarch/berserkarch:base-devel
```

```bash
docker run -it --rm \
    --security-opt seccomp=unconfined \
    --hostname berserk \
    --name berserkarch \
    --privileged \
    -p 5901:5901 \
    -p 6080:6080 \
    -p 22:22 \
    -p 8080:8080 \
    berserkarch/berserkarch:novnc
```
