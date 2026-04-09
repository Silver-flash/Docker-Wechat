#!/bin/bash
set -e

WECHAT_BINS=("/opt/wechat/wechat" "/opt/wechat-beta/wechat" "$(command -v wechat 2>/dev/null)")
WECHAT_BIN=""
for bin in "${WECHAT_BINS[@]}"; do
    [ -n "${bin}" ] && [ -x "${bin}" ] && WECHAT_BIN="${bin}" && break
done
[ -z "${WECHAT_BIN}" ] && echo "[ERROR] WeChat not found" && exit 1

# Create XDG_RUNTIME_DIR required by dbus / pulseaudio
mkdir -p /run/user/1000
chmod 700 /run/user/1000
chown wechat:wechat /run/user/1000

# /home/wechat is bind-mounted from the host (./data on the host).
# Fix ownership so the in-container `wechat` user (uid 1000) can read/write.
mkdir -p /home/wechat
chown wechat:wechat /home/wechat
# Only chown top-level entries shallowly to avoid huge recursive chowns on
# every start; deeper trees are owned correctly after first creation.
find /home/wechat -maxdepth 1 -mindepth 1 -not -user wechat -exec chown -R wechat:wechat {} + 2>/dev/null || true

# Prepare log file; tail it so WeChat output appears in docker logs
touch /tmp/wechat.log
chown wechat:wechat /tmp/wechat.log
tail -f /tmp/wechat.log &

# Write wrapper to /tmp (NOT /home/wechat — that path is bind-mounted from
# the host and would shadow anything we put there).
WRAPPER=/tmp/run-wechat.sh
cat > "${WRAPPER}" <<EOF
#!/bin/bash
export XDG_RUNTIME_DIR=/run/user/1000

# Start a dbus session bus (required by WeChat/CEF and ibus)
eval \$(dbus-launch --sh-syntax 2>/dev/null) || true

# ─── IBus IME env vars (Chromium/CEF has first-class IBus support) ───
export XMODIFIERS=@im=ibus
export GTK_IM_MODULE=ibus
export QT_IM_MODULE=ibus

# Refresh ibus engine cache so libpinyin is discoverable
ibus write-cache --system 2>/dev/null || ibus write-cache 2>/dev/null || true

# Pre-register engines in dconf BEFORE ibus-daemon starts (it only reads
# preload-engines at startup). dconf-service needs to be installed.
dconf write /desktop/ibus/general/preload-engines "['xkb:us::eng', 'libpinyin']" 2>/dev/null || true
dconf write /desktop/ibus/general/engines-order "['xkb:us::eng', 'libpinyin']" 2>/dev/null || true

# Start ibus-daemon with X11 backend (now it will pick up the preloaded engines)
ibus-daemon -drx 2>/dev/null &

# Wait until ibus is responsive
for i in 1 2 3 4 5 6 7 8 9 10; do
    if ibus engine >/dev/null 2>&1; then
        echo "[WRAPPER] ibus ready after \${i}*0.3s" >> /tmp/wechat.log
        break
    fi
    sleep 0.3
done

# Default to English keyboard; the toggle button switches to libpinyin
ibus engine xkb:us::eng 2>/dev/null || true
echo "[WRAPPER] ibus engines: \$(ibus list-engine 2>/dev/null | grep -E 'libpinyin|xkb:us' | tr '\n' ' ')" >> /tmp/wechat.log

# Start UTF-8 clipboard injection + IME toggle server
python3 /scripts/type-server.py &

echo "[WRAPPER] Launching: ${WECHAT_BIN}" >> /tmp/wechat.log

# Launch WeChat (Chromium picks up GTK_IM_MODULE=ibus automatically)
${WECHAT_BIN} \\
    --no-sandbox \\
    --password-store=basic \\
    >> /tmp/wechat.log 2>&1 &
WECHAT_PID=\$!
echo "[WRAPPER] WeChat PID=\$WECHAT_PID" >> /tmp/wechat.log

# Brief check: did it crash immediately?
sleep 2
if ! kill -0 \$WECHAT_PID 2>/dev/null; then
    echo "[WRAPPER] WeChat exited immediately!" >> /tmp/wechat.log
    wait \$WECHAT_PID
    echo "[WRAPPER] Exit code: \$?" >> /tmp/wechat.log
    exit 1
fi
echo "[WRAPPER] WeChat still running after 2s — OK" >> /tmp/wechat.log

# Background monitor: every 3 s keep WeChat window visible and centered/maximized
(
while kill -0 \$WECHAT_PID 2>/dev/null; do
    sleep 3
    # Search by PID (not --onlyvisible, so off-screen windows are found too)
    WIN=\$(xdotool search --pid \$WECHAT_PID 2>/dev/null | tail -1)
    [ -z "\$WIN" ] && continue

    # Get current display and window geometry
    read DISP_W DISP_H < <(xdotool getdisplaygeometry 2>/dev/null)
    WIN_GEOM=\$(xdotool getwindowgeometry "\$WIN" 2>/dev/null)
    WIN_X=\$(echo "\$WIN_GEOM" | grep -oP 'Position: \K[0-9]+')
    WIN_Y=\$(echo "\$WIN_GEOM" | grep -oP 'Position: [0-9]+,\K[0-9]+')
    WIN_W=\$(echo "\$WIN_GEOM" | grep -oP 'Geometry: \K[0-9]+')
    WIN_H=\$(echo "\$WIN_GEOM" | grep -oP 'Geometry: [0-9]+x\K[0-9]+')

    [ -z "\$DISP_W" ] || [ -z "\$WIN_W" ] && continue

    # If window is off-screen or nearly so, center it
    MAX_X=\$(( DISP_W - WIN_W ))
    MAX_Y=\$(( DISP_H - WIN_H ))
    if [ "\$WIN_X" -gt "\$MAX_X" ] || [ "\$WIN_Y" -gt "\$MAX_Y" ] 2>/dev/null; then
        CENTER_X=\$(( (DISP_W - WIN_W) / 2 ))
        CENTER_Y=\$(( (DISP_H - WIN_H) / 2 ))
        xdotool windowmove "\$WIN" "\$CENTER_X" "\$CENTER_Y" 2>/dev/null
        echo "[MONITOR] Moved window to center (\${CENTER_X},\${CENTER_Y})" >> /tmp/wechat.log
    fi

    # Try to maximize if the window allows it (main window after login)
    xdotool windowmaximize "\$WIN" 2>/dev/null || true
done
) &

wait \$WECHAT_PID
echo "[WRAPPER] WeChat ended (exit \$?)" >> /tmp/wechat.log
EOF
chmod +x "${WRAPPER}"
chown wechat:wechat "${WRAPPER}"

echo "[INFO] WeChat : ${WECHAT_BIN}"
echo "[INFO] Browser: http://localhost:6080"

# Note: no 'exec' here so background tail -f above keeps running
su - wechat -c "
    xpra start :1 \
      --bind-ws=0.0.0.0:6080 \
      --html=on \
      --start-child=${WRAPPER} \
      --exit-with-children=no \
      --no-daemon \
      --resize-display=yes \
      --encoding=auto \
      --clipboard=yes \
      --clipboard-direction=both \
      --notifications=no \
      --speaker=disabled \
      --microphone=disabled \
      2>&1
"
