# Flannel DPDK OKE Node Pool for an Existing Cluster

This Terraform package adds a DPDK validation node pool to an existing **flannel** OKE cluster. It does not create a cluster, VCN, subnets, or IAM policy.

It creates:

- One OKE managed node pool using `FLANNEL_OVERLAY`.
- One manually attached secondary OCI VNIC per worker instance.
- `network_launch_type = "VFIO"` for the OKE VM SR-IOV/DPDK-capable path.
- Cloud-init that configures 2Mi and 1Gi hugepages and restarts kubelet.
- Rendered Kubernetes validation manifests under `rendered-manifests/`.

The rendered manifests include:

- `00-namespace.yaml`
- `01-hugepages-smoke.yaml`
- `02-flannel-hostdevice-multus-test.yaml`

## Usage

```bash
cd /Users/chipinghwang/Desktop/projects/dpdk/terraform/dpdk-nodepool-existing-cluster
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with the existing flannel cluster OCID, compartment OCID, worker subnet, secondary VNIC subnet, OKE image OCID, SSH public key, and target PCI address.

If using local OCI security-token auth, refresh first:

```bash
cd /Users/chipinghwang/Desktop/projects/dpdk
./oci-login.sh
cd terraform/dpdk-nodepool-existing-cluster
```

Then run:

```bash
terraform init
terraform plan
terraform apply
```

## Validation

Wait for the new flannel node to join:

```bash
kubectl get nodes -l dpdk.oracle.com/nodepool=dpdk-hugepages -o wide
kubectl get nodes -l dpdk.oracle.com/nodepool=dpdk-hugepages -o json | jq '.items[].status.allocatable'
```

Confirm the secondary VNIC is visible on the worker node before running PCI tests:

```bash
kubectl debug node/<node-name> -it --image=docker.io/library/ubuntu:22.04 -- chroot /host bash
ip -br link
lspci -nnk | egrep -A3 'Mellanox|Ethernet'
dpdk-devbind.py -s
```

Apply the read-only smoke test first:

```bash
kubectl apply -f rendered-manifests/00-namespace.yaml
kubectl apply -f rendered-manifests/01-hugepages-smoke.yaml
kubectl -n dpdk-validation logs -f dpdk-hugepages-smoke
```

Then run the flannel + Multus `host-device` test after confirming `test_pci_address` matches the node-side PCI device:

```bash
kubectl apply -f rendered-manifests/02-flannel-hostdevice-multus-test.yaml
kubectl -n dpdk-validation get pod dpdk-flannel-hostdevice-test \
  -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}'
kubectl -n dpdk-validation logs -f dpdk-flannel-hostdevice-test
```

Expected pod networking evidence is flannel default networking on `eth0` plus the host-device attachment on `net1`.

Before applying the Multus test, make sure Multus is installed in the cluster and the target PCI device exists on the selected node.

## Notes

- This package is additive: it only creates a new node pool and local rendered manifest files.
- The test manifests are not applied by Terraform.
- The node pool intentionally uses `FLANNEL_OVERLAY` only.
- The secondary VNIC is attached with `oci_core_vnic_attachment`, not OKE GVA.
- The `test_pci_address` value is environment-specific. Confirm with `lspci -nnk` or `dpdk-devbind.py -s` on the new node before applying PCI tests.
- For the Mellanox `mlx5_core` path, the key pod evidence is flannel `eth0`, Multus `net1`, hugepages, `/dev/infiniband`, `ibv_devices`, and `dpdk-testpmd -a <PCI_BDF>`.
