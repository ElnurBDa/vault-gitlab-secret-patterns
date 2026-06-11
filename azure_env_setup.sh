
#!/usr/bin/env bash
set -euo pipefail
 
# ── Config ────────────────────────────────────────────────────────────────
RG="RG-Test"
LOC="westeurope"
VNET="sre-vnet"
SUBNET="sre-subnet"
SUBNET_PREFIX="10.10.1.0/24"
VNET_PREFIX="10.10.0.0/16"
NSG_PROXY="proxy-nsg"
ADMIN_USER="elnur"
SSH_KEY="${HOME}/.ssh/id_rsa.pub"          # adjust if you use ed25519: ~/.ssh/id_ed25519.pub
IMAGE="Ubuntu2404"                          # latest LTS alias (Canonical 24.04)
 
# NOTE: no Azure SKU has exactly 4 vCPU / 4 GiB. F4s_v2 (4 vCPU / 8 GiB)
# is the leanest 4-vCPU option. Swap if you prefer e.g. Standard_D4as_v5.
SIZE_MAIN="Standard_F4s_v2"
SIZE_PROXY="Standard_B2s"                   # 2 vCPU / 4 GiB (B1s's 1 GiB proved flaky)
SIZE_BIG="Standard_D4as_v5"
 
INTERNAL_VMS=(gitlab-runner prod secman)
 
# ── Cloud-init: docker + compose plugin on internal hosts ─────────────────
CLOUD_INIT=$(mktemp)
cat > "$CLOUD_INIT" <<EOF
#cloud-config
package_update: true
runcmd:
  - curl -fsSL https://get.docker.com | sh
  - usermod -aG docker ${ADMIN_USER}
  - systemctl enable --now docker
EOF
 
# ── Network ───────────────────────────────────────────────────────────────
az network vnet create \
  -g "$RG" -l "$LOC" -n "$VNET" \
  --address-prefix "$VNET_PREFIX" \
  --subnet-name "$SUBNET" \
  --subnet-prefix "$SUBNET_PREFIX"
 
# NSG for proxy only: SSH from internet
az network nsg create -g "$RG" -l "$LOC" -n "$NSG_PROXY"
az network nsg rule create \
  -g "$RG" --nsg-name "$NSG_PROXY" -n allow-ssh \
  --priority 1000 --direction Inbound --access Allow \
  --protocol Tcp --destination-port-ranges 22
 
# ── Proxy (public, jump host) ─────────────────────────────────────────────
az vm create \
  -g "$RG" -l "$LOC" -n proxy \
  --image "$IMAGE" --size "$SIZE_PROXY" \
  --vnet-name "$VNET" --subnet "$SUBNET" \
  --nsg "$NSG_PROXY" \
  --public-ip-sku Standard \
  --admin-username "$ADMIN_USER" \
  --ssh-key-values "$SSH_KEY"

# ── Gitlab -------------------─────────────────────────────────────────────
az vm create \
  -g "$RG" -l "$LOC" -n proxy \
  --image "$IMAGE" --size "$SIZE_BIG" \
  --vnet-name "$VNET" --subnet "$SUBNET" \
  --nsg "" \
  --public-ip-address "" \
  --admin-username "$ADMIN_USER" \
  --ssh-key-values "$SSH_KEY" \
  --custom-data "$CLOUD_INIT" \
  --no-wait

# ── Internal hosts (no public IP, reachable via proxy) ────────────────────
for vm in "${INTERNAL_VMS[@]}"; do
  az vm create \
    -g "$RG" -l "$LOC" -n "$vm" \
    --image "$IMAGE" --size "$SIZE_MAIN" \
    --vnet-name "$VNET" --subnet "$SUBNET" \
    --nsg "" \
    --public-ip-address "" \
    --admin-username "$ADMIN_USER" \
    --ssh-key-values "$SSH_KEY" \
    --custom-data "$CLOUD_INIT" \
    --no-wait
done
 
az vm wait --created --ids $(az vm list -g "$RG" --query "[].id" -o tsv)
rm -f "$CLOUD_INIT"
 
# ── Summary ───────────────────────────────────────────────────────────────
PROXY_IP=$(az vm show -d -g "$RG" -n proxy --query publicIps -o tsv)
echo
echo "Proxy public IP: $PROXY_IP"
echo "Private IPs:"
az vm list -g "$RG" -d --query "[].{name:name, ip:privateIps}" -o table

# ── Summary ───────────────────────────────────────────────────────────────
PROXY_IP=$(az vm show -d -g "$RG" -n proxy --query publicIps -o tsv)
echo
echo "Proxy public IP: $PROXY_IP"
echo "Private IPs:"
az vm list -g "$RG" -d --query "[].{name:name, ip:privateIps}" -o table
echo
echo "Access internal hosts via ProxyJump, e.g.:"
echo "  ssh -J ${ADMIN_USER}@${PROXY_IP} ${ADMIN_USER}@<private-ip>"

# ── SSH config ────────────────────────────────────────────────────────────

INTERNAL_VMS=(gitlab gitlab-runner prod secman)

echo "The .ssh/config:"
echo "Host sre-proxy"
echo "    HostName ${PROXY_IP}"
echo "    User ${ADMIN_USER}"
echo
for vm in "${INTERNAL_VMS[@]}"; do
ip=$(az vm show -d -g "$RG" -n "$vm" --query privateIps -o tsv)
echo "Host ${vm}"
echo "    HostName ${ip}"
echo "    User ${ADMIN_USER}"
echo "    ProxyJump sre-proxy"
echo
done

