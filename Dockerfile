FROM ubuntu:22.04

LABEL maintainer="dockerwechat"
LABEL description="WeChat Linux in Docker via Xpra HTML5"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    ca-certificates wget curl \
    # Xpra (HTML5 client bundled)
    xpra \
    # Chinese input injection
    xclip xdotool python3 \
    # Chinese fonts
    fonts-wqy-microhei fonts-wqy-zenhei fonts-noto-cjk \
    # WeChat (CEF) runtime libraries
    libgbm1 libxkbcommon0 libxkbcommon-x11-0 \
    libgtk-3-0 libnss3 libatk1.0-0 libatk-bridge2.0-0 \
    libcups2 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
    libpango-1.0-0 libcairo2 libasound2 libdbus-1-3 \
    libdrm2 libxshmfence1 libglu1-mesa libatomic1 \
    libxcb-xkb1 libxcb-icccm4 libxcb-image0 \
    libxcb-render-util0 libxcb-keysyms1 libxcb-shape0 \
    pulseaudio procps dbus dbus-x11 \
    ibus ibus-libpinyin ibus-gtk3 ibus-gtk4 \
    dconf-cli dconf-service \
    && rm -rf /var/lib/apt/lists/*

# Download and install WeChat
ARG WECHAT_URL=https://dldir1v6.qq.com/weixin/Universal/Linux/WeChatLinux_x86_64.deb
RUN wget -O /tmp/wechat.deb "${WECHAT_URL}" \
    && dpkg -i /tmp/wechat.deb \
    || (apt-get install -f -y && dpkg -i /tmp/wechat.deb) \
    && rm /tmp/wechat.deb

# Create non-root user
RUN useradd -m -s /bin/bash wechat && \
    mkdir -p /home/wechat/.xwechat && \
    chown -R wechat:wechat /home/wechat

# Custom Xpra HTML5 UI (override index + inject custom CSS)
COPY novnc/index.html  /usr/share/xpra/www/index.html
COPY novnc/custom.css  /usr/share/xpra/www/css/custom.css

# Scripts
COPY scripts/ /scripts/
RUN chmod +x /scripts/start.sh

EXPOSE 6080 7070

VOLUME ["/home/wechat/.xwechat"]

HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
    CMD curl -f http://localhost:6080/ || exit 1

CMD ["/scripts/start.sh"]
