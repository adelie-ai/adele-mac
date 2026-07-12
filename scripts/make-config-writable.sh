#!/usr/bin/env bash
# ============================================================================
# Make the lab adele-daemon's config writable, so the Mac app's Settings
# (connections / purposes / personality / MCP) can persist changes.
#
# The daemon persists settings by writing daemon.toml, but it's currently a
# read-only ConfigMap subPath mount → every write fails ("couldn't write
# daemon.toml"). This switches the config dir to a writable PVC, seeded once from
# the existing ConfigMap via an initContainer (so nothing is lost). Works with
# the current daemon image — no rebuild needed.
#
# Trade-off: after this, the ConfigMap becomes a FIRST-BOOT SEED only. The PVC is
# authoritative; later ConfigMap edits (e.g. enable-bedrock.sh) won't propagate
# unless you clear the PVC copy:
#   kubectl -n <ns> exec deploy/adele-daemon -- rm -f ~/.config/desktop-assistant/daemon.toml
#   kubectl -n <ns> rollout restart deploy/adele-daemon   # re-seeds from the ConfigMap
# (Once a daemon image with self-bootstrap ships, even the seed is optional.)
#
# Idempotent — safe to re-run.
# ============================================================================
set -euo pipefail

KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/lab.yaml}"
NAMESPACE="${NAMESPACE:-adele-test}"
DEPLOY="${DEPLOY:-adele-daemon}"
CONFIGMAP="${CONFIGMAP:-adele-daemon-config}"
PVC="${PVC:-adele-config}"
PVC_SIZE="${PVC_SIZE:-64Mi}"
STORAGE_CLASS="${STORAGE_CLASS:-local-path}"     # cluster has two "default" SCs; pin one
SEED_IMAGE="${SEED_IMAGE:-busybox:stable}"
CONFIG_DIR="${CONFIG_DIR:-/home/assistant/.config/desktop-assistant}"
ASSUME_YES="${ASSUME_YES:-0}"

export KUBECONFIG="$KUBECONFIG_PATH"
fail() { echo "error: $*" >&2; exit 1; }
command -v kubectl >/dev/null || fail "kubectl not found"
command -v python3 >/dev/null || fail "python3 not found"

echo "Context : $(kubectl config current-context)"
echo "Target  : $NAMESPACE/$DEPLOY   config dir=$CONFIG_DIR"
echo "PVC     : $PVC ($PVC_SIZE, $STORAGE_CLASS)   seed image=$SEED_IMAGE"
kubectl -n "$NAMESPACE" get deploy "$DEPLOY" >/dev/null || fail "deployment not found"

if [[ "$ASSUME_YES" != "1" ]]; then
    read -r -p "Apply writable-config change to the cluster? [y/N] " reply
    [[ "$reply" == "y" || "$reply" == "Y" ]] || { echo "aborted."; exit 0; }
fi

# --- 1) PVC for the writable config dir --------------------------------------
echo ">> [1/3] PVC $PVC"
kubectl -n "$NAMESPACE" apply -f - <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $PVC
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: $STORAGE_CLASS
  resources:
    requests:
      storage: $PVC_SIZE
YAML

# --- 2) Patch the deployment (volumes, mounts, seed initContainer) -----------
echo ">> [2/3] patch deploy/$DEPLOY"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
kubectl -n "$NAMESPACE" get deploy "$DEPLOY" -o json > "$work/dep.json"

python3 - "$work/dep.json" "$PVC" "$SEED_IMAGE" "$CONFIG_DIR" <<'PY'
import json, sys
dep_path, pvc, seed_image, config_dir = sys.argv[1:5]
dep = json.load(open(dep_path))
spec = dep["spec"]["template"]["spec"]
container = spec["containers"][0]

DATA_VOL = "config-data"     # writable PVC
CM_VOL = "config"            # existing ConfigMap volume (becomes the seed source)
SEED_DIR = "/seed"

# Volumes: keep the ConfigMap volume; add the PVC volume.
vols = spec.setdefault("volumes", [])
if not any(v.get("name") == DATA_VOL for v in vols):
    vols.append({"name": DATA_VOL, "persistentVolumeClaim": {"claimName": pvc}})

# Daemon container mounts: drop the read-only ConfigMap subPath mount; mount the
# writable PVC at the whole config dir.
mounts = [m for m in container.get("volumeMounts", []) if m.get("name") != CM_VOL]
if not any(m.get("name") == DATA_VOL for m in mounts):
    mounts.append({"name": DATA_VOL, "mountPath": config_dir})
container["volumeMounts"] = mounts

# Seed initContainer: copy the ConfigMap's daemon.toml into the PVC once (only if
# the PVC has no config yet), preserving runtime edits across restarts.
inits = spec.setdefault("initContainers", [])
inits = [ic for ic in inits if ic.get("name") != "seed-config"]
inits.append({
    "name": "seed-config",
    "image": seed_image,
    "command": ["sh", "-c",
                f"test -f {config_dir}/daemon.toml || "
                f"(mkdir -p {config_dir} && cp {SEED_DIR}/daemon.toml {config_dir}/daemon.toml)"],
    "volumeMounts": [
        {"name": CM_VOL, "mountPath": SEED_DIR, "readOnly": True},
        {"name": DATA_VOL, "mountPath": config_dir},
    ],
})
spec["initContainers"] = inits

# Strip fields that conflict with `kubectl apply`.
md = dep.get("metadata", {})
for k in ("resourceVersion", "uid", "creationTimestamp", "managedFields", "generation"):
    md.pop(k, None)
dep["metadata"] = md
dep.pop("status", None)
json.dump(dep, open(dep_path, "w"), indent=2)
print(f"  volumes: +{DATA_VOL}(pvc)  mounts: {CM_VOL} subPath -> {DATA_VOL} at {config_dir}")
print("  initContainers: + seed-config (copy-if-missing)")
PY

kubectl -n "$NAMESPACE" apply -f "$work/dep.json" >/dev/null

# --- 3) Restart --------------------------------------------------------------
echo ">> [3/3] rollout restart"
kubectl -n "$NAMESPACE" rollout restart deploy/"$DEPLOY"
kubectl -n "$NAMESPACE" rollout status deploy/"$DEPLOY" --timeout=180s

cat <<EOF

✅ Done. The daemon's config dir is now a writable PVC ($PVC), seeded from the
   ConfigMap. Settings changes from the Mac app will now persist.

Verify:
  kubectl -n $NAMESPACE exec deploy/$DEPLOY -- cat $CONFIG_DIR/daemon.toml | head
  # Then add a Bedrock connection from the app's Settings > Connections — it
  # should save without the "couldn't write daemon.toml" error.
EOF
