#!/bin/bash
# setup_iscsi.sh — Setup zvols + LIO target dans VM + initiator + mounts host
set -e
SSH="ssh -i $HOME/.ssh/id_ed25519_new -o StrictHostKeyChecking=no ubuntu@zfs-qos"
VM_IP="192.168.122.187"
IQN_BASE="iqn.2026-04.qos-test"

echo "=== [VM] Create 5 zvols ==="
for i in 1 2 3 4 5; do
    $SSH "sudo zfs create -s -V 2G testqos/iscsi${i}" || echo "zvol $i may exist"
done
$SSH "sudo zfs list -t volume"

echo "=== [VM] Configure LIO target with 5 LUNs ==="
$SSH "sudo targetcli /backstores/block create name=lun1 dev=/dev/zvol/testqos/iscsi1 || true
sudo targetcli /backstores/block create name=lun2 dev=/dev/zvol/testqos/iscsi2 || true
sudo targetcli /backstores/block create name=lun3 dev=/dev/zvol/testqos/iscsi3 || true
sudo targetcli /backstores/block create name=lun4 dev=/dev/zvol/testqos/iscsi4 || true
sudo targetcli /backstores/block create name=lun5 dev=/dev/zvol/testqos/iscsi5 || true
sudo targetcli /iscsi create ${IQN_BASE}:target1 || true
sudo targetcli /iscsi/${IQN_BASE}:target1/tpg1/luns create /backstores/block/lun1 0 || true
sudo targetcli /iscsi/${IQN_BASE}:target1/tpg1/luns create /backstores/block/lun2 1 || true
sudo targetcli /iscsi/${IQN_BASE}:target1/tpg1/luns create /backstores/block/lun3 2 || true
sudo targetcli /iscsi/${IQN_BASE}:target1/tpg1/luns create /backstores/block/lun4 3 || true
sudo targetcli /iscsi/${IQN_BASE}:target1/tpg1/luns create /backstores/block/lun5 4 || true
sudo targetcli /iscsi/${IQN_BASE}:target1/tpg1/portals delete 0.0.0.0 3260 || true
sudo targetcli /iscsi/${IQN_BASE}:target1/tpg1/portals create ${VM_IP} 3260 || true
sudo targetcli /iscsi/${IQN_BASE}:target1/tpg1 set attribute authentication=0 generate_node_acls=1 demo_mode_write_protect=0
sudo targetcli saveconfig"

echo "=== [HOST] iSCSI discovery + login ==="
sudo iscsiadm -m discovery -t st -p ${VM_IP}:3260
sudo iscsiadm -m node -T ${IQN_BASE}:target1 -p ${VM_IP}:3260 -l

# Wait a moment for devices
sleep 2
echo "=== [HOST] lsscsi after login ==="
lsscsi 2>/dev/null || sudo apt-get install -y lsscsi 2>&1 | tail -2
lsscsi 2>&1 | grep -i linux-io || true

echo "=== [HOST] Format + mount ==="
# Get 5 new sdX devices from iscsi
DEVS=$(lsscsi 2>/dev/null | awk '/LIO-ORG/{print $NF}' | sort)
echo "Detected: $DEVS"
i=1
for dev in $DEVS; do
    echo "Processing LUN $i -> $dev"
    sudo mkfs.ext4 -F -q -L iscsi${i} $dev
    sudo mkdir -p /mnt/iscsi${i}
    sudo mount $dev /mnt/iscsi${i}
    i=$((i+1))
done

echo "=== Result ==="
mount | grep iscsi
