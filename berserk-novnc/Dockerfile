FROM berserkarch/berserkarch:latest

RUN pacman -Syu --noconfirm make && \
  # Install packages
  pacman -Syu --noconfirm openssh git vim tmux screen supervisor iw man mlocate pciutils less bash-completion novnc \
  xorg-server-xvfb x11vnc xfce4 xfce4-goodies xfce4-power-manager ttf-liberation && \
  # Copy BerserkArch configs
  cp -r /etc/skel/. /root/. && \
  rm -f /usr/bin/websockify && \
  echo 'root:berserk' | chpasswd && \
  echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config

# Expose needed ports
EXPOSE 22/tcp
EXPOSE 8080/tcp

# Set operable environment
ENV DISPLAY=:0

COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

WORKDIR /root
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf", "--pidfile", "/run/supervisord.pid"]
ENTRYPOINT []
