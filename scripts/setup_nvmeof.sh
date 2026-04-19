#!/bin/bash
# setup_nvmeof.sh — Setup NVMe-oF TCP target dans VM + initiator host + mounts
# 5 zvols testqos/nvme1..5 (512M each), nvmet-tcp, port 4420
set -e
SSH="ssh -i $HOME/.ssh/id_ed25519_new -o StrictHostKeyChecking=no ubuntu@zfs-qos"
VM_IP="192.168.122.187"
NQN_BASE="nqn.2026-04.com.qos-test"

echo "=== [VM] Create 5 zvols (512M each) + boost_pool=1 ==="
for i in 1 2 3 4 5; do
    $SSH "sudo zfs create -s -V 512M testqos/nvme${i}" || echo "zvol $i may exist"
    $SSH "sudo zfs set qos:boost_pool=1 testqos/nvme${i}"
done
$SSH "sudo zfs list -t volume | grep nvme"
$SSH "zfs get qos:boost_pool -r testqos | grep nvme"

echo "=== [VM] Load nvmet modules ==="
$SSH "sudo modprobe nvmet; sudo modprobe nvmet-tcp; lsmod | grep nvmet"

echo "=== [VM] Install nvme-cli if missing ==="
$SSH "which nvme >/dev/null 2>&1 || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nvme-cli 2>&1 | tail -2"

echo "=== [VM] Setup nvmet configfs ==="
$SSH "sudo mkdir -p /sys/kernel/config/nvmet/subsystems
sudo mkdir -p /sys/kernel/config/nvmet/ports/1"

# Port config
$SSH "echo ${VM_IP} | sudo tee /sys/kernel/config/nvmet/ports/1/addr_traddr > /dev/null || true
echo tcp | sudo tee /sys/kernel/config/nvmet/ports/1/addr_trtype > /dev/null || true
echo 4420 | sudo tee /sys/kernel/config/nvmet/ports/1/addr_trsvcid > /dev/null || true
echo ipv4 | sudo tee /sys/kernel/config/nvmet/ports/1/addr_adrfam > /dev/null || true"

for i in 1 2 3 4 5; do
    NQN="${NQN_BASE}:nvme${i}"
    echo "--- Subsystem $NQN ---"
    $SSH "sudo mkdir -p /sys/kernel/config/nvmet/subsystems/${NQN}
echo 1 | sudo tee /sys/kernel/config/nvmet/subsystems/${NQN}/attr_allow_any_host > /dev/null
sudo mkdir -p /sys/kernel/config/nvmet/subsystems/${NQN}/namespaces/1
echo /dev/zvol/testqos/nvme${i} | sudo tee /sys/kernel/config/nvmet/subsystems/${NQN}/namespaces/1/device_path > /dev/null
echo 1 | sudo tee /sys/kernel/config/nvmet/subsystems/${NQN}/namespaces/1/enable > /dev/null
sudo ln -sf /sys/kernel/config/nvmet/subsystems/${NQN} /sys/kernel/config/nvmet/ports/1/subsystems/${NQN} 2>/dev/null || true"
done

echo "=== [HOST] Load nvme-tcp ==="
sudo modprobe nvme-tcp
lsmod | grep nvme_tcp

echo "=== [HOST] Install nvme-cli if missing ==="
which nvme >/dev/null 2>&1 || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nvme-cli 2>&1 | tail -2

echo "=== [HOST] Discover + connect 5 subsystems ==="
sudo nvme discover -t tcp -a ${VM_IP} -s 4420 | tail -30 || true

for i in 1 2 3 4 5; do
    NQN="${NQN_BASE}:nvme${i}"
    sudo nvme connect -t tcp -a ${VM_IP} -s 4420 -n ${NQN} 2>&1 | tail -2 || echo "connect $i may already be connected"
done

sleep 2
echo "=== [HOST] nvme list ==="
sudo nvme list

echo "=== [HOST] Detect nvme block devices for QoS test ==="
# STRICT filter: ONLY ModelNumber == "Linux" (the nvmet-tcp target identifier).
# Previous versions used substring matching on 'nvme' in device name which matched
# host disks (e.g. Samsung NVMe SSDs named /dev/nvme0n1) and nearly triggered
# mkfs.ext4 on the system disk. Never loosen this filter.
mapfile -t DEVS < <(sudo nvme list -o json 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
for dev in d.get('Devices', []):
    if dev.get('ModelNumber','').strip() == 'Linux':
        print(dev.get('DevicePath',''))
" | sort)

echo "Final NVMe devs (${#DEVS[@]}): ${DEVS[@]}"

if [ ${#DEVS[@]} -ne 5 ]; then
    echo "FATAL: expected exactly 5 NVMe-oF target devices (ModelNumber=Linux), got ${#DEVS[@]}"
    echo "       Refusing to format anything. Host disks may be at risk if filter widens."
    exit 1
fi

# SAFETY: ensure none of the detected devices are currently mounted as system.
for dev in "${DEVS[@]}"; do
    if mount | grep -qE "^${dev}( on /| on /boot)"; then
        echo "FATAL: $dev is mounted as a system filesystem. Aborting."
        exit 1
    fi
done

echo "=== [HOST] Format + mount ==="
i=1
for dev in "${DEVS[@]}"; do
    [ $i -gt 5 ] && break
    echo "Processing /mnt/nvme${i} -> $dev"
    sudo mkfs.ext4 -F -q -L nvme${i} $dev
    sudo mkdir -p /mnt/nvme${i}
    mountpoint -q /mnt/nvme${i} && sudo umount /mnt/nvme${i} || true
    sudo mount $dev /mnt/nvme${i}
    i=$((i+1))
done

echo "=== Result ==="
mount | grep nvme
df -h /mnt/nvme* 2>/dev/null
