#!/bin/bash
# setup_cifs.sh — Setup samba sur VM + mount cifs1..5 côté host
# Réutilise testqos/bench1..5 (partagés avec NFS)
set -e
SSH="ssh -i $HOME/.ssh/id_ed25519_new -o StrictHostKeyChecking=no ubuntu@zfs-qos"
VM_IP="192.168.122.187"
CIFS_USER="qosuser"
CIFS_PASS="qospass"

echo "=== [VM] Install samba ==="
$SSH "dpkg -l | grep -q '^ii  samba ' || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y samba smbclient 2>&1 | tail -3"

echo "=== [VM] Create smb user ==="
$SSH "id ${CIFS_USER} 2>/dev/null || sudo useradd -r -s /usr/sbin/nologin ${CIFS_USER}
(echo ${CIFS_PASS}; echo ${CIFS_PASS}) | sudo smbpasswd -a -s ${CIFS_USER} 2>&1 | tail -2"

echo "=== [VM] chown datasets to smb user ==="
for i in 1 2 3 4 5; do
    $SSH "sudo chown ${CIFS_USER}:${CIFS_USER} /testqos/bench${i}"
    $SSH "sudo chmod 0770 /testqos/bench${i}"
done

echo "=== [VM] Write smb.conf ==="
$SSH "sudo tee /etc/samba/smb.conf > /dev/null" <<'SMBCONF'
[global]
   workgroup = WORKGROUP
   server string = ZFS QoS CIFS
   security = user
   map to guest = never
   log file = /var/log/samba/log.%m
   max log size = 1000
   server min protocol = SMB2
   server signing = auto
   # Perf
   socket options = TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=131072 SO_SNDBUF=131072

[bench1]
   path = /testqos/bench1
   browseable = yes
   read only = no
   valid users = qosuser
   force user = qosuser
[bench2]
   path = /testqos/bench2
   browseable = yes
   read only = no
   valid users = qosuser
   force user = qosuser
[bench3]
   path = /testqos/bench3
   browseable = yes
   read only = no
   valid users = qosuser
   force user = qosuser
[bench4]
   path = /testqos/bench4
   browseable = yes
   read only = no
   valid users = qosuser
   force user = qosuser
[bench5]
   path = /testqos/bench5
   browseable = yes
   read only = no
   valid users = qosuser
   force user = qosuser
SMBCONF

echo "=== [VM] Restart samba ==="
$SSH "sudo systemctl restart smbd nmbd; sudo systemctl status smbd --no-pager | head -5"

echo "=== [HOST] Install cifs-utils ==="
which mount.cifs >/dev/null 2>&1 || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y cifs-utils 2>&1 | tail -2

echo "=== [HOST] Credentials file ==="
sudo tee /root/.cifs-qos > /dev/null <<CREDS
username=${CIFS_USER}
password=${CIFS_PASS}
CREDS
sudo chmod 600 /root/.cifs-qos

echo "=== [HOST] Mount cifs1..5 ==="
for i in 1 2 3 4 5; do
    sudo mkdir -p /mnt/cifs${i}
    # unmount if already mounted
    mountpoint -q /mnt/cifs${i} && sudo umount /mnt/cifs${i} || true
    sudo mount.cifs //${VM_IP}/bench${i} /mnt/cifs${i} -o credentials=/root/.cifs-qos,vers=3.0,uid=$(id -u),gid=$(id -g),forceuid,forcegid,rw,noperm
    echo "  /mnt/cifs${i}: $(mountpoint -q /mnt/cifs${i} && echo OK || echo MISS)"
done

echo "=== Result ==="
mount | grep cifs
