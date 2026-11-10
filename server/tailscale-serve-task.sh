# Paste into DSM Task Scheduler as a user-defined script, user ROOT. Run once.
# Publishes PocketBase on the tailnet at https://<nas-name>.<tailnet>.ts.net:8443 (tailnet only).
OUT=/volume1/docker/nas-sync/serve-setup.txt
TS=/var/packages/Tailscale/target/bin/tailscale
[ -x "$TS" ] || TS=$(command -v tailscale)
{
  echo "== $(date)"
  echo "tailscale: $TS"
  "$TS" serve --bg --https=8443 http://127.0.0.1:8090
  echo "-- serve status:"
  "$TS" serve status
  echo "-- local check:"
  wget -q -O - http://127.0.0.1:8090/api/health || echo "pocketbase not answering on 127.0.0.1:8090"
  echo
  echo "== done"
} > "$OUT" 2>&1
