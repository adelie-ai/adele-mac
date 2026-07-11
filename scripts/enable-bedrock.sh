#!/usr/bin/env bash
# ============================================================================
# Enable AWS Bedrock on the lab `adele-daemon`.
#
# What it does (idempotent — safe to re-run):
#   1. Creates/updates a Secret with your AWS credentials.
#   2. Wires those keys into the daemon Deployment as env vars.
#   3. Edits daemon.toml in the ConfigMap: adds [connections.bedrock] and
#      repoints the chosen purpose(s) at a Bedrock model.
#   4. Restarts the daemon and waits for rollout.
#
# Credentials are read from the ENVIRONMENT (not stored in this file). Run like:
#
#   AWS_ACCESS_KEY_ID=AKIA... \
#   AWS_SECRET_ACCESS_KEY=... \
#   AWS_REGION=us-east-1 \
#   BEDROCK_MODEL=us.anthropic.claude-sonnet-4-6 \
#   ./scripts/enable-bedrock.sh
#
# If you already have AWS creds exported in your shell, they're picked up
# automatically — you only need AWS_REGION and BEDROCK_MODEL.
#
# Prereqs on your side:
#   - The IAM identity has: bedrock:InvokeModelWithResponseStream,
#     bedrock:Converse, bedrock:ConverseStream, bedrock:ListFoundationModels.
#   - The model has access GRANTED in the Bedrock console for that region
#     (Bedrock is opt-in per model).
# ============================================================================
set -euo pipefail

# --- Inputs (env-driven; override any of the optionals inline) ---------------
AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-}"          # only for temporary creds
AWS_REGION="${AWS_REGION:-}"                        # e.g. us-east-1
BEDROCK_MODEL="${BEDROCK_MODEL:-}"                  # e.g. us.anthropic.claude-sonnet-4-6

KUBECONFIG_PATH="${KUBECONFIG:-$HOME/.kube/lab.yaml}"
NAMESPACE="${NAMESPACE:-adele-test}"
DEPLOY="${DEPLOY:-adele-daemon}"
CONFIGMAP="${CONFIGMAP:-adele-daemon-config}"
SECRET="${SECRET:-adele-aws}"
# Space-separated subset of: interactive dreaming consolidation titling
REPOINT_PURPOSES="${REPOINT_PURPOSES:-interactive}"
ASSUME_YES="${ASSUME_YES:-0}"                       # set 1 to skip the prompt
# ----------------------------------------------------------------------------

export KUBECONFIG="$KUBECONFIG_PATH"

fail() { echo "error: $*" >&2; exit 1; }
command -v kubectl >/dev/null || fail "kubectl not found on PATH"
command -v python3 >/dev/null || fail "python3 not found on PATH"

[[ -n "$AWS_ACCESS_KEY_ID"     ]] || fail "AWS_ACCESS_KEY_ID is not set"
[[ -n "$AWS_SECRET_ACCESS_KEY" ]] || fail "AWS_SECRET_ACCESS_KEY is not set"
[[ -n "$AWS_REGION"            ]] || fail "AWS_REGION is not set (e.g. us-east-1)"
[[ -n "$BEDROCK_MODEL"         ]] || fail "BEDROCK_MODEL is not set (e.g. us.anthropic.claude-sonnet-4-6)"

echo "Context : $(kubectl config current-context)"
echo "Namespace: $NAMESPACE   Deploy: $DEPLOY"
echo "Region  : $AWS_REGION"
echo "Model   : $BEDROCK_MODEL"
echo "Repoint : $REPOINT_PURPOSES"
kubectl -n "$NAMESPACE" get deploy "$DEPLOY" >/dev/null || fail "deployment $DEPLOY not found in $NAMESPACE"

if [[ "$ASSUME_YES" != "1" ]]; then
    read -r -p "Apply these changes to the cluster? [y/N] " reply
    [[ "$reply" == "y" || "$reply" == "Y" ]] || { echo "aborted."; exit 0; }
fi

# --- 1) Secret (keys named so `set env --from` maps them 1:1) ----------------
echo ">> [1/4] secret/$SECRET"
secret_args=(
    --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"
    --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"
    --from-literal=AWS_REGION="$AWS_REGION"
)
[[ -n "$AWS_SESSION_TOKEN" ]] && secret_args+=(--from-literal=AWS_SESSION_TOKEN="$AWS_SESSION_TOKEN")
kubectl -n "$NAMESPACE" create secret generic "$SECRET" "${secret_args[@]}" \
    --dry-run=client -o yaml | kubectl -n "$NAMESPACE" apply -f -

# --- 2) Inject the secret's keys as env on the deployment --------------------
echo ">> [2/4] env <- secret/$SECRET on deploy/$DEPLOY"
kubectl -n "$NAMESPACE" set env deploy/"$DEPLOY" --from=secret/"$SECRET" >/dev/null

# --- 3) Edit daemon.toml in the ConfigMap ------------------------------------
echo ">> [3/4] configmap/$CONFIGMAP (daemon.toml)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
kubectl -n "$NAMESPACE" get configmap "$CONFIGMAP" -o json > "$work/cm.json"

base_url="https://bedrock-runtime.${AWS_REGION}.amazonaws.com"
python3 - "$work/cm.json" "$base_url" "$BEDROCK_MODEL" "$REPOINT_PURPOSES" <<'PY'
import json, sys
cm_path, base_url, model, purposes = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].split()
cm = json.load(open(cm_path))
toml = cm["data"]["daemon.toml"]

def drop_section(text, header):
    """Remove a [header] block (up to the next top-level table or EOF)."""
    out, skip = [], False
    for ln in text.splitlines(keepends=True):
        s = ln.strip()
        if s == f"[{header}]":
            skip = True
            continue
        if skip and s.startswith("[") and s.endswith("]"):
            skip = False
        if not skip:
            out.append(ln)
    return "".join(out)

# [connections.bedrock]
toml = drop_section(toml, "connections.bedrock")
toml = toml.rstrip() + "\n\n" + (
    "[connections.bedrock]\n"
    'type = "bedrock"\n'
    f'base_url = "{base_url}"\n'
    "max_context_tokens = 200000\n"
)

# repoint purposes at the Bedrock model
for p in purposes:
    toml = drop_section(toml, f"purposes.{p}")
    toml = toml.rstrip() + "\n\n" + (
        f"[purposes.{p}]\n"
        'connection = "bedrock"\n'
        f'model = "{model}"\n'
    )

cm["data"]["daemon.toml"] = toml.rstrip() + "\n"

# Strip fields that would conflict with `kubectl apply`.
md = cm.get("metadata", {})
for k in ("resourceVersion", "uid", "creationTimestamp", "managedFields", "generation"):
    md.pop(k, None)
cm["metadata"] = md
cm.pop("status", None)
json.dump(cm, open(cm_path, "w"), indent=2)

print("---- new [connections.bedrock] / [purposes.*] ----")
print("[connections.bedrock]  base_url =", base_url)
for p in purposes:
    print(f"[purposes.{p}]  -> bedrock / {model}")
PY

kubectl -n "$NAMESPACE" apply -f "$work/cm.json" >/dev/null

# --- 4) Restart to pick up env + config --------------------------------------
echo ">> [4/4] rollout restart deploy/$DEPLOY"
kubectl -n "$NAMESPACE" rollout restart deploy/"$DEPLOY"
kubectl -n "$NAMESPACE" rollout status deploy/"$DEPLOY" --timeout=180s

cat <<EOF

✅ Done.

Verify:
  # daemon picked up Bedrock (look for the connection / no auth errors)
  kubectl -n $NAMESPACE logs deploy/$DEPLOY --tail=80 | grep -iE 'bedrock|connection|error'

  # end-to-end from the Mac client (port-forward must be running):
  #   kubectl -n $NAMESPACE port-forward svc/$DEPLOY 11339:11339
  # then in adele-mac:
  #   ADELE_WS_URL=ws://127.0.0.1:11339/ws ADELE_WS_USER=adele ADELE_WS_PASS=... \\
  #   ADELE_MGMT=1 swift run AdeleSmoke        # should list the 'bedrock' connection

  # In the app: the model picker will list Bedrock models, and
  # Settings > Purposes > Interactive should show: $BEDROCK_MODEL
EOF
