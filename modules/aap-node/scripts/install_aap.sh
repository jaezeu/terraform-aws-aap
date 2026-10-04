#!/usr/bin/env bash
# =============================================================================
# install_aap.sh -- bootstrap a single-node containerized Red Hat Ansible
# Automation Platform ("growth topology") on a RHEL EC2 instance.
#
# Runs once as root from cloud-init (runcmd). It is deliberately static:
#   * environment-specific settings -> /opt/aap/install.env  (rendered by Terraform)
#   * secrets                       -> AWS SSM Parameter Store (read via the instance role)
#   * inventory skeleton            -> /opt/aap/inventory.tmpl (rendered by Terraform)
#
# Progress goes to /var/log/aap-install.log and is published to the SSM
# parameter $STATUS_PARAM and the instance tag aap:status
# (pending -> installing -> ready | failed).
# =============================================================================
set -Eeuo pipefail

WORKDIR="${WORKDIR:-/opt/aap}"
ENV_FILE="${ENV_FILE:-${WORKDIR}/install.env}"
LOG_FILE="${LOG_FILE:-/var/log/aap-install.log}"

exec > >(tee -a "${LOG_FILE}") 2>&1
echo "=== [$(date -u +%FT%TZ)] AAP bootstrap starting ==="

# shellcheck disable=SC1090
source "${ENV_FILE}"
: "${AAP_HOSTNAME:?}" "${AWS_REGION:?}" "${SSM_PREFIX:?}" "${STATUS_PARAM:?}" "${AAP_VERSION:?}"
INSTALL_USER="${INSTALL_USER:-aap}"
AAP_INSTALLER_TYPE="${AAP_INSTALLER_TYPE:-setup}"
INSTALL_SSM_AGENT="${INSTALL_SSM_AGENT:-true}"
AAP_URL="${AAP_URL:-https://${AAP_HOSTNAME}}"
ADMIN_USERNAME="admin"
START_TS=$(date +%s)
INSTANCE_ID=""
IMDS_TOKEN=""

RH_SSO_URL="https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token"
RH_API_URL="https://api.access.redhat.com/management/v1"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
die() { log "ERROR: $*"; exit 1; }

# retry <attempts> <command...>  (logs only the command name: arguments may hold tokens)
retry() {
  local attempts=$1 n=1
  shift
  until "$@"; do
    if [ "${n}" -ge "${attempts}" ]; then
      return 1
    fi
    log "attempt ${n}/${attempts} of '$1' failed -- retrying in $((n * 15))s"
    sleep $((n * 15))
    n=$((n + 1))
  done
}

imds() {
  curl -sf --max-time 5 -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
    "http://169.254.169.254/latest/meta-data/$1"
}

set_status() {
  log "status -> $1"
  command -v aws >/dev/null 2>&1 || return 0
  aws ssm put-parameter --region "${AWS_REGION}" --name "${STATUS_PARAM}" \
    --type String --value "$1" --overwrite >/dev/null 2>&1 || true
  if [ -n "${INSTANCE_ID}" ]; then
    aws ec2 create-tags --region "${AWS_REGION}" --resources "${INSTANCE_ID}" \
      --tags "Key=aap:status,Value=$1" >/dev/null 2>&1 || true
  fi
}

on_error() {
  log "!!! bootstrap FAILED at line $1 -- see ${LOG_FILE}"
  set_status failed
  exit 1
}
trap 'on_error ${LINENO}' ERR

# Offline token -> short-lived access token for the Red Hat APIs
rh_access_token() {
  curl -fsS --retry 3 -X POST "${RH_SSO_URL}" \
    -d grant_type=refresh_token -d client_id=rhsm-api \
    --data-urlencode "refresh_token=${RH_OFFLINE_TOKEN}" | jq -r '.access_token // empty'
}

# -----------------------------------------------------------------------------
# 1. Packages. The Red Hat AWS AMIs use RHUI, so no subscription-manager needed.
# -----------------------------------------------------------------------------
log "installing base packages"
retry 5 dnf install -y ansible-core podman tar wget git-core rsync jq unzip gettext

if ! command -v aws >/dev/null 2>&1; then
  log "installing AWS CLI v2"
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip
  unzip -q -o /tmp/awscliv2.zip -d /tmp/awscliv2
  /tmp/awscliv2/aws/install --update >/dev/null
  rm -rf /tmp/awscliv2 /tmp/awscliv2.zip
fi

if [ "${INSTALL_SSM_AGENT}" = "true" ]; then
  log "installing SSM Agent"
  if retry 3 dnf install -y "https://s3.${AWS_REGION}.amazonaws.com/amazon-ssm-${AWS_REGION}/latest/linux_amd64/amazon-ssm-agent.rpm"; then
    systemctl enable --now amazon-ssm-agent >/dev/null 2>&1 || true
  else
    log "WARN: SSM Agent install failed; Session Manager will not be available"
  fi
fi

# -----------------------------------------------------------------------------
# 2. Instance identity; wait for the Elastic IP to be attached
# -----------------------------------------------------------------------------
IMDS_TOKEN=$(curl -sf --max-time 5 -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(imds instance-id)
PRIVATE_IP=$(imds local-ipv4)
set_status installing
log "instance=${INSTANCE_ID} private_ip=${PRIVATE_IP} hostname=${AAP_HOSTNAME}"

if [ -n "${EXPECTED_PUBLIC_IP:-}" ]; then
  log "waiting for Elastic IP ${EXPECTED_PUBLIC_IP} to be associated"
  for _ in $(seq 1 60); do
    if [ "$(imds public-ipv4 2>/dev/null || true)" = "${EXPECTED_PUBLIC_IP}" ]; then
      break
    fi
    sleep 10
  done
  if [ "$(imds public-ipv4 2>/dev/null || true)" != "${EXPECTED_PUBLIC_IP}" ]; then
    log "WARN: Elastic IP still not attached after 10 minutes; continuing"
  fi
fi

# -----------------------------------------------------------------------------
# 3. Hostname. AAP bakes it into certificates and service URLs, and every
#    component has to resolve it to this host.
# -----------------------------------------------------------------------------
hostnamectl set-hostname "${AAP_HOSTNAME}"
{ grep -vw "${AAP_HOSTNAME}" /etc/hosts || true; } > /etc/hosts.aap
printf '%s %s %s\n' "${PRIVATE_IP}" "${AAP_HOSTNAME}" "${AAP_HOSTNAME%%.*}" >> /etc/hosts.aap
cat /etc/hosts.aap > /etc/hosts
rm -f /etc/hosts.aap

# -----------------------------------------------------------------------------
# 4. Secrets from SSM Parameter Store (SecureString, decrypted with the role)
# -----------------------------------------------------------------------------
get_param() {
  aws ssm get-parameter --region "${AWS_REGION}" --name "${SSM_PREFIX}/$1" \
    --with-decryption --query 'Parameter.Value' --output text 2>/dev/null || true
}
ADMIN_PASSWORD=$(get_param admin_password)
PG_PASSWORD=$(get_param pg_password)
REGISTRY_USERNAME=$(get_param registry_username)
REGISTRY_PASSWORD=$(get_param registry_password)
RH_OFFLINE_TOKEN=$(get_param redhat_offline_token)
if [ "${RH_OFFLINE_TOKEN}" = "unset" ]; then
  RH_OFFLINE_TOKEN=""
fi
if [ -z "${ADMIN_PASSWORD}" ] || [ -z "${PG_PASSWORD}" ]; then
  die "admin/postgres passwords missing under ${SSM_PREFIX} (check the instance role)"
fi
if [ -z "${REGISTRY_USERNAME}" ] || [ -z "${REGISTRY_PASSWORD}" ]; then
  die "registry.redhat.io credentials missing under ${SSM_PREFIX}"
fi

# -----------------------------------------------------------------------------
# 5. Installation user: non-root, passwordless sudo, lingering user session
#    (rootless podman + systemd --user need it when run from cloud-init).
# -----------------------------------------------------------------------------
if ! id "${INSTALL_USER}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "${INSTALL_USER}"
fi
echo "${INSTALL_USER} ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/90-${INSTALL_USER}"
chmod 0440 "/etc/sudoers.d/90-${INSTALL_USER}"
loginctl enable-linger "${INSTALL_USER}"
INSTALL_UID=$(id -u "${INSTALL_USER}")
for _ in $(seq 1 30); do
  if [ -S "/run/user/${INSTALL_UID}/bus" ]; then
    break
  fi
  sleep 1
done
mkdir -p "${WORKDIR}"

# -----------------------------------------------------------------------------
# 6. Installer tarball: S3 > URL > Red Hat Customer Portal API (latest build)
# -----------------------------------------------------------------------------
TARBALL="${WORKDIR}/aap-containerized-${AAP_INSTALLER_TYPE}.tar.gz"
if [ -n "${INSTALLER_S3_URI:-}" ]; then
  log "downloading installer from ${INSTALLER_S3_URI}"
  retry 3 aws s3 cp --region "${AWS_REGION}" --only-show-errors "${INSTALLER_S3_URI}" "${TARBALL}"
elif [ -n "${INSTALLER_URL:-}" ]; then
  log "downloading installer from URL"
  retry 3 curl -fL --retry 3 -o "${TARBALL}" "${INSTALLER_URL}"
elif [ -n "${RH_OFFLINE_TOKEN}" ]; then
  RHEL_MAJOR=$(. /etc/os-release && echo "${VERSION_ID%%.*}")
  CSET="ansible-automation-platform-${AAP_VERSION}-for-rhel-${RHEL_MAJOR}-$(uname -m)-files"
  PREFIX="ansible-automation-platform-containerized-${AAP_INSTALLER_TYPE}-${AAP_VERSION}"
  log "looking up the latest ${PREFIX}* in content set ${CSET}"
  RH_TOKEN=$(rh_access_token)
  if [ -z "${RH_TOKEN}" ]; then
    die "could not obtain a Red Hat API access token (offline token invalid or expired after 30 days of inactivity?)"
  fi
  IMAGES=$(curl -fsS --retry 3 -H "Authorization: Bearer ${RH_TOKEN}" "${RH_API_URL}/images/cset/${CSET}?limit=100")
  IMAGE_JSON=$(jq -c --arg p "${PREFIX}" \
    '[.body[]? | select(.filename | startswith($p))] | sort_by(.datePublished) | last // empty' <<<"${IMAGES}")
  if [ -z "${IMAGE_JSON}" ]; then
    die "no installer matching ${PREFIX}* in ${CSET}. Available: $(jq -r '[.body[]?.filename] | join(", ")' <<<"${IMAGES}")"
  fi
  FILENAME=$(jq -r '.filename' <<<"${IMAGE_JSON}")
  HREF=$(jq -r '.downloadHref' <<<"${IMAGE_JSON}")
  log "downloading ${FILENAME}"
  retry 3 curl -fL --retry 3 -H "Authorization: Bearer ${RH_TOKEN}" -o "${TARBALL}" "${HREF}"
else
  die "no installer source configured: set redhat_offline_token, aap_installer_s3_uri or aap_installer_url"
fi

log "extracting installer"
tar -xzf "${TARBALL}" -C "${WORKDIR}"
SETUP_DIR=$(find "${WORKDIR}" -maxdepth 1 -type d -name 'ansible-automation-platform-containerized-setup*' | sort -V | tail -n 1)
if [ -z "${SETUP_DIR}" ]; then
  die "could not find the extracted setup directory in ${WORKDIR}"
fi
log "installer directory: ${SETUP_DIR}"

# -----------------------------------------------------------------------------
# 7. Subscription manifest (optional): S3 object, or exported via the RHSM API
#    from a subscription allocation (GET export -> poll exportJob -> download).
# -----------------------------------------------------------------------------
LICENSE_FILE=""
if [ -n "${MANIFEST_S3_URI:-}" ]; then
  log "downloading subscription manifest from ${MANIFEST_S3_URI}"
  retry 3 aws s3 cp --region "${AWS_REGION}" --only-show-errors "${MANIFEST_S3_URI}" "${WORKDIR}/manifest.zip"
  LICENSE_FILE="${WORKDIR}/manifest.zip"
elif [ -n "${RHSM_ALLOCATION_UUID:-}" ] && [ -n "${RH_OFFLINE_TOKEN}" ]; then
  log "exporting subscription manifest for allocation ${RHSM_ALLOCATION_UUID}"
  RH_TOKEN=$(rh_access_token)
  ALLOC_URL="${RH_API_URL}/allocations/${RHSM_ALLOCATION_UUID}"
  JOB_ID=$(curl -fsS --retry 3 -H "Authorization: Bearer ${RH_TOKEN}" "${ALLOC_URL}/export" | jq -r '.body.exportJobID // empty')
  if [ -z "${JOB_ID}" ]; then
    die "manifest export request failed (check the allocation UUID and that it has an AAP subscription attached)"
  fi
  EXPORT_ID=""
  for _ in $(seq 1 30); do
    RESP=$(curl -sS -w '\n%{http_code}' -H "Authorization: Bearer ${RH_TOKEN}" "${ALLOC_URL}/exportJob/${JOB_ID}")
    CODE=${RESP##*$'\n'}
    if [ "${CODE}" = "200" ]; then
      EXPORT_ID=$(printf '%s' "${RESP%$'\n'*}" | jq -r '.body.exportID // empty')
      break
    fi
    sleep 20
  done
  if [ -z "${EXPORT_ID}" ]; then
    die "manifest export did not complete in time"
  fi
  retry 3 curl -fL --retry 3 -H "Authorization: Bearer ${RH_TOKEN}" -H "Accept: application/zip" \
    -o "${WORKDIR}/manifest.zip" "${ALLOC_URL}/export/${EXPORT_ID}"
  LICENSE_FILE="${WORKDIR}/manifest.zip"
else
  log "no manifest configured: attach a subscription in the AAP UI after the first login"
fi

# -----------------------------------------------------------------------------
# 8. Render the inventory. Only the listed placeholders are substituted.
# -----------------------------------------------------------------------------
export ADMIN_PASSWORD PG_PASSWORD REGISTRY_USERNAME REGISTRY_PASSWORD LICENSE_FILE SETUP_DIR
envsubst '${ADMIN_PASSWORD} ${PG_PASSWORD} ${REGISTRY_USERNAME} ${REGISTRY_PASSWORD} ${LICENSE_FILE} ${SETUP_DIR}' \
  < "${WORKDIR}/inventory.tmpl" > "${WORKDIR}/inventory"
if [ -z "${LICENSE_FILE}" ]; then
  sed -i '/^controller_license_file=$/d' "${WORKDIR}/inventory"
fi
chown -R "${INSTALL_USER}:${INSTALL_USER}" "${WORKDIR}"
chmod 0600 "${WORKDIR}/inventory"

# -----------------------------------------------------------------------------
# 9. Run the installer as the installation user (retried once: it is idempotent)
# -----------------------------------------------------------------------------
cat > "${WORKDIR}/run-installer.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export XDG_RUNTIME_DIR=/run/user/\$(id -u)
export DBUS_SESSION_BUS_ADDRESS=unix:path=\${XDG_RUNTIME_DIR}/bus
export ANSIBLE_COLLECTIONS_PATH="${SETUP_DIR}/collections"
export ANSIBLE_FORCE_COLOR=0
cd "${SETUP_DIR}"
exec ansible-playbook -i "${WORKDIR}/inventory" ansible.containerized_installer.install
EOF
chown "${INSTALL_USER}:${INSTALL_USER}" "${WORKDIR}/run-installer.sh"
chmod 0750 "${WORKDIR}/run-installer.sh"

log "running the AAP containerized installer (expect 20-40 minutes)"
if ! sudo -iu "${INSTALL_USER}" "${WORKDIR}/run-installer.sh"; then
  log "installer failed, retrying once in 30s"
  sleep 30
  sudo -iu "${INSTALL_USER}" "${WORKDIR}/run-installer.sh"
fi

# -----------------------------------------------------------------------------
# 10. Verify through the platform gateway, then publish the status
# -----------------------------------------------------------------------------
CURL_AUTH_FILE="${WORKDIR}/.curl-auth"
ESCAPED_PASSWORD=${ADMIN_PASSWORD//\\/\\\\}
ESCAPED_PASSWORD=${ESCAPED_PASSWORD//\"/\\\"}
printf 'user = "%s:%s"\n' "${ADMIN_USERNAME}" "${ESCAPED_PASSWORD}" > "${CURL_AUTH_FILE}"
chmod 0600 "${CURL_AUTH_FILE}"

log "waiting for ${AAP_URL}/api/controller/v2/ping/"
CODE="000"
for _ in $(seq 1 60); do
  CODE=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 -K "${CURL_AUTH_FILE}" \
    "${AAP_URL}/api/controller/v2/ping/" || true)
  if [ "${CODE}" = "200" ]; then
    break
  fi
  sleep 10
done
rm -f "${CURL_AUTH_FILE}"
if [ "${CODE}" != "200" ]; then
  die "AAP API did not become ready (last HTTP status ${CODE})"
fi

mkdir -p /etc/motd.d
cat > /etc/motd.d/aap <<EOF

  Ansible Automation Platform ${AAP_VERSION}
    URL      : ${AAP_URL}
    User     : ${ADMIN_USERNAME}  (password: SSM ${SSM_PREFIX}/admin_password)
    Log      : ${LOG_FILE}
    Installer: ${SETUP_DIR}  (inventory: ${WORKDIR}/inventory, user: ${INSTALL_USER})

EOF

set_status ready
log "=== AAP is ready at ${AAP_URL} (took $(( ($(date +%s) - START_TS) / 60 )) minutes) ==="
