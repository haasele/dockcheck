sudo tee /etc/profile.d/dockcheck-motd.sh >/dev/null <<'EOF'
# Shows a banner on SSH login, that prints out update info
if [ -t 1 ] && [ -s /var/log/dockcheck_updates.txt ] && ! grep -qx 'None' /var/log/dockcheck_updates.txt; then
  printf '\n[dockcheck] Updates available (Stand %s):\n' "$(date -r /var/log/dockcheck_updates.txt '+%Y-%m-%d %H:%M')"
  cat /var/log/dockcheck_updates.txt
  echo
fi
EOF
