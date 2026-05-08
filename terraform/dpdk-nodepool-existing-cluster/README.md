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

## Input Variables

| Variable | Required | Default | What it controls |
| --- | --- | --- | --- |
| `region` | Yes | none | OCI region where the existing flannel OKE cluster and node-pool resources exist. |
| `oci_profile` | No | `DEFAULT` | OCI config profile used by the Terraform OCI provider. Use `customer` for the local security-token workflow. |
| `oci_auth` | No | `SecurityToken` | OCI provider authentication mode. Keep `SecurityToken` when using `./oci-login.sh` / OCI CLI token auth. |
| `compartment_id` | Yes | none | Compartment OCID where the new node pool and VNIC attachments are created. |
| `cluster_id` | Yes | none | Existing OKE cluster OCID. This stack adds a node pool to that cluster. |
| `kubernetes_version` | Yes | none | Kubernetes version for the new node pool. It must be compatible with the existing cluster. |
| `node_pool_name` | No | `dpdk-hugepages` | Name assigned to the new DPDK validation node pool and used as the default node-label value. |
| `node_count` | No | `1` | Number of worker nodes to create in the node pool. |
| `max_pods_per_node` | No | `31` | Maximum Kubernetes pod capacity per worker node for this flannel node pool. This is not the number of DPDK test pods; a single host-device PCI attachment cannot be shared by multiple pods at the same time. |
| `node_shape` | No | `VM.Standard.E5.Flex` | Compute shape for each worker node. |
| `ocpus` | No | `4` | OCPU count for flexible shapes. |
| `memory_in_gbs` | No | `32` | Memory size for flexible shapes. Leave enough memory for the hugepages reserved by cloud-init. |
| `node_image_id` | Yes | none | OKE worker image OCID to boot the nodes from. |
| `ssh_public_key` | Yes | none | SSH public key text injected into the worker nodes. Marked sensitive in Terraform. |
| `placement_configs` | Yes | none | Availability domain and worker subnet placement for the node pool. Add one entry per placement target. |
| `network_launch_type` | No | `VFIO` | OKE node-pool network launch type for the SR-IOV/DPDK-capable VM path. |
| `attach_secondary_vnic` | No | `true` | Whether Terraform manually attaches one secondary OCI VNIC to each worker instance after the node pool is created. |
| `secondary_vnic_subnet_id` | Required when `attach_secondary_vnic=true` | empty | Subnet OCID used for each manually attached secondary VNIC. |
| `secondary_vnic_display_name_prefix` | No | `dpdk-secondary-vnic` | Display-name prefix for the secondary VNIC and its attachment. |
| `secondary_vnic_assign_public_ip` | No | `false` | Whether the secondary VNIC should receive a public IP. Keep false for the validated private secondary-VNIC path. |
| `secondary_vnic_skip_source_dest_check` | No | `false` | Whether to disable source/destination checking on the secondary VNIC. |
| `secondary_vnic_nsg_ids` | No | `null` | Optional NSG OCIDs to attach to the secondary VNIC. |
| `node_freeform_tags` | No | `{}` | Freeform tags applied to the node pool. |
| `node_label_key` | No | `dpdk.oracle.com/nodepool` | Kubernetes label key added to nodes and used by the rendered test pods for scheduling. |
| `test_namespace` | No | `dpdk-validation` | Namespace used by rendered validation manifests. |
| `test_pci_address` | No | `0000:01:00.0` | PCI BDF used by the rendered Multus `host-device` NAD and `dpdk-testpmd` allowlist. Confirm this on the actual node before applying the test manifest. |
| `test_hugepages_2mi` | No | `512Mi` | 2Mi hugepage request and limit used by rendered validation pods. |
| `test_hugepages_1gi` | No | `1Gi` | 1Gi hugepage size kept for templates/future tests. The current rendered smoke tests use 2Mi hugepages. |

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
