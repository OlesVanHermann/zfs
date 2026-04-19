#!/bin/bash
# qos_env.sh — Configuration centralisée pour toute la suite QoS
# Source par full_setup.sh, verify_all.sh, chain_*.sh

# ─── Connexions VM ────────────────────────────────────────────────────
LNX_VM_IP=192.168.122.187
BSD_VM_IP=192.168.122.137
LNX_VM_HOST=zfs-qos
BSD_VM_HOST=zfs-bsd-qos
SSH_KEY="$HOME/.ssh/id_ed25519_new"
SSH_OPTS="-o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10"
LNX_SSH="ssh -i $SSH_KEY $SSH_OPTS ubuntu@$LNX_VM_IP"
BSD_SSH="ssh -i $SSH_KEY $SSH_OPTS freebsd@$BSD_VM_IP"

# ─── Libvirt VM names ─────────────────────────────────────────────────
LNX_VM_NAME="zfs-qos"
BSD_VM_NAME="zfs-qos-bsd-qos"

# ─── Pool ──────────────────────────────────────────────────────────────
POOL=testqos

# ─── Datasets filesystem (shared across LOCAL, NFS, CIFS) ─────────────
DS_BENCH=(bench1 bench2 bench3 bench4 bench5)

# ─── Datasets zvol — iSCSI (2G each) ──────────────────────────────────
DS_ISCSI=(iscsi1 iscsi2 iscsi3 iscsi4 iscsi5)
ISCSI_ZVOL_SIZE=2G

# ─── Datasets zvol — NVMe-oF ──────────────────────────────────────────
DS_NVME_LNX=(nvme1 nvme2 nvme3 nvme4 nvme5)       # 512M on Linux VM
DS_NVME_BSD=(nvmeof1 nvmeof2 nvmeof3 nvmeof4 nvmeof5)  # on FreeBSD VM
NVME_ZVOL_SIZE=512M

# ─── iSCSI targets ────────────────────────────────────────────────────
LNX_ISCSI_IQN="iqn.2026-04.com.qos:bench"
BSD_ISCSI_IQN="iqn.2026-04.local.zfs-qos-bsd:target0"
ISCSI_PORT=3260

# ─── NVMe-oF ──────────────────────────────────────────────────────────
LNX_NVME_NQN="nqn.2026-04.local.zfs-qos-linux:nvme"
BSD_NVME_NQN="nqn.2026-04.local.zfs-qos-bsd:nvme"
NVME_PORT=4420

# ─── CIFS ──────────────────────────────────────────────────────────────
CIFS_USER=qosuser
CIFS_PASS=qospass
CIFS_CREDS=/root/.cifs-qos

# ─── Host mount base paths ────────────────────────────────────────────
MNT_NFS_LNX=/mnt/linux/nfs
MNT_NFS_BSD=/mnt/freebsd/nfs
MNT_CIFS_LNX=/mnt/linux/cifs
MNT_CIFS_BSD=/mnt/freebsd/cifs
MNT_ISCSI_LNX=/mnt/linux/iscsi
MNT_ISCSI_BSD=/mnt/freebsd/iscsi
MNT_NVME_LNX=/mnt/linux/nvmeof
MNT_NVME_BSD=/mnt/freebsd/nvmeof

# ─── NFS mount options ────────────────────────────────────────────────
NFS_LNX_OPTS="rw,soft,timeo=50,retrans=3"
NFS_BSD_OPTS="rw,soft,timeo=50,retrans=3,vers=3"

# ─── CIFS mount options ───────────────────────────────────────────────
CIFS_MOUNT_OPTS="credentials=$CIFS_CREDS,vers=3.0,uid=$(id -u),gid=$(id -g),forceuid,forcegid,rw,noperm,soft"

# ─── Test parameters ──────────────────────────────────────────────────
FIO_SIZE_DEFAULT=192M
FIO_SIZE_NVME=128M
DUR_DEFAULT=60

# ─── Colors ────────────────────────────────────────────────────────────
RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; CYN=$'\e[36m'; RST=$'\e[0m'

# ─── Helpers ───────────────────────────────────────────────────────────
log_ok()   { echo "  ${GRN}OK${RST}   $*"; }
log_fail() { echo "  ${RED}FAIL${RST} $*"; }
log_warn() { echo "  ${YEL}WARN${RST} $*"; }
log_info() { echo "  ${CYN}INFO${RST} $*"; }

section() {
    echo ""
    echo "══════════════════════════════════════════════════════════════"
    echo "  $*"
    echo "══════════════════════════════════════════════════════════════"
}
