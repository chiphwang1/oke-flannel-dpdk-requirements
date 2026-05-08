# Requirements to Run DPDK on an OKE Flannel Worker

This document lists what is required to run a DPDK workload in a pod on an OKE Flannel worker using a manually attached secondary OCI VNIC and Multus `host-device`.

It intentionally omits validation steps. Use it as a requirements and configuration reference.

## Terraform

A Terraform package for adding a DPDK validation node pool to an existing OKE Flannel cluster is included at:

```text
terraform/dpdk-nodepool-existing-cluster
```

It creates a `FLANNEL_OVERLAY` node pool, configures boot-time hugepages with cloud-init, manually attaches one secondary OCI VNIC per worker instance, and renders Multus `host-device` test manifests.

## Required Worker Setup

The worker node must have:

- OKE VM worker node pool created with `network-launch-type: VFIO`.
- A manually attached secondary OCI VNIC.
- The secondary VNIC visible on the worker as a Linux interface, for example `enp1s0`.
- The secondary VNIC mapped to a PCI address, for example `0000:01:00.0`.
- The PCI VF left on the Linux `mlx5_core` driver.
- Multus installed.
- The `host-device` CNI plugin installed under `/opt/cni/bin`.

Do not bind the secondary VNIC to `vfio-pci` for this working path. The validated path uses Mellanox `mlx5_core` plus the DPDK `mlx5` PMD.

## Required Node CNI Plugins

These binaries must exist on each target worker under:

```text
/opt/cni/bin
```

Required or commonly needed plugins:

| Plugin | Why it is needed |
| --- | --- |
| `host-device` | Required. Moves the secondary VNIC PCI device from the worker node into the pod network namespace as `net1`. |
| `bridge` | Common base plugin used by bridge-style pod networking and Multus default-network flows. Some pod setup paths fail if it is missing. |
| `host-local` | Provides local IP address management for CNI networks that need IP allocation. The DPDK `host-device` path can use `ipam: {}`, but this plugin is still commonly expected. |
| `loopback` | Sets up the pod loopback interface. Standard CNI installations normally include it. |
| `portmap` | Supports hostPort-style mappings for CNI-managed pods. |
| `tuning` | Commonly bundled with the standard CNI plugins and useful when a CNI attachment needs sysctl or interface tuning. Installed by the validated DaemonSet for completeness. |
| `firewall` | Commonly bundled with the standard CNI plugins and useful for CNI-managed firewall behavior. Installed by the validated DaemonSet for completeness. |

Minimal installer DaemonSet:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: install-cni-host-device
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: install-cni-host-device
  template:
    metadata:
      labels:
        app: install-cni-host-device
    spec:
      hostNetwork: true
      tolerations:
      - operator: Exists
      containers:
      - name: installer
        image: docker.io/library/alpine:3.20
        securityContext:
          privileged: true
        env:
        - name: CNI_PLUGIN_VERSION
          value: v1.9.1
        command:
        - /bin/sh
        - -lc
        - |
          set -eux
          apk add --no-cache curl tar
          arch="$(uname -m)"
          case "$arch" in
            x86_64) cni_arch=amd64 ;;
            aarch64) cni_arch=arm64 ;;
            *) echo "unsupported arch: $arch" >&2; exit 1 ;;
          esac
          url="https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGIN_VERSION}/cni-plugins-linux-${cni_arch}-${CNI_PLUGIN_VERSION}.tgz"
          work="$(mktemp -d)"
          curl -fsSL "$url" -o "$work/cni.tgz"
          tar -xzf "$work/cni.tgz" -C "$work"
          for plugin in bridge host-device host-local loopback portmap tuning firewall; do
            if [ -f "$work/$plugin" ]; then
              install -m 0755 "$work/$plugin" "/host/opt/cni/bin/$plugin"
            fi
          done
          sleep infinity
        volumeMounts:
        - name: cni-bin
          mountPath: /host/opt/cni/bin
      volumes:
      - name: cni-bin
        hostPath:
          path: /opt/cni/bin
          type: Directory
```

## Required NetworkAttachmentDefinition

The pod needs a Multus network that uses CNI type `host-device`.

Replace `0000:01:00.0` with the PCI address of the secondary VNIC on the target worker.

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: flannel-dpdk-hostdevice
  namespace: dpdk-flannel-test
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "type": "host-device",
      "name": "flannel-dpdk-hostdevice",
      "pciBusID": "0000:01:00.0",
      "ipam": {}
    }
```

`ipam: {}` is intentional for this DPDK path. The DPDK process uses the PCI device directly, so the secondary pod interface does not need an IP address for the basic DPDK dataplane path.

## Required Pod Settings

The pod must include:

- Multus network annotation pointing to the `host-device` NAD.
- Node pinning to the worker that owns the requested PCI address.
- Privileged security context.
- Linux capabilities needed by DPDK and network setup.
- `/dev/infiniband` mounted from the host.
- DPDK runtime packages and Mellanox userspace dependencies.

Required annotation:

```yaml
metadata:
  annotations:
    k8s.v1.cni.cncf.io/networks: dpdk-flannel-test/flannel-dpdk-hostdevice
```

Required node pinning:

```yaml
spec:
  nodeSelector:
    kubernetes.io/hostname: "10.0.4.108"
```

Required security context:

```yaml
securityContext:
  privileged: true
  capabilities:
    add:
    - IPC_LOCK
    - SYS_ADMIN
    - NET_ADMIN
    - NET_RAW
```

Why these are needed:

| Setting | Why it is needed |
| --- | --- |
| `privileged: true` | Allows the container to access host device files and low-level network/device operations needed by DPDK. |
| `IPC_LOCK` | Allows memory locking. DPDK often locks memory to avoid paging. |
| `SYS_ADMIN` | Broad system capability often needed for low-level device, namespace, and mount-related operations. |
| `NET_ADMIN` | Allows network interface operations inside the pod network namespace. |
| `NET_RAW` | Allows raw packet operations. Useful for low-level packet tools and some network paths. |

When `privileged: true` is set, Kubernetes already grants these capabilities. They are listed to show the access the validated test expected and to help derive a narrower security context for production.

Required host device mounts:

```yaml
volumeMounts:
- name: infiniband
  mountPath: /dev/infiniband
volumes:
- name: infiniband
  hostPath:
    path: /dev/infiniband
    type: DirectoryOrCreate
```

Why these are needed:

| Host path | Why it is needed |
| --- | --- |
| `/dev/infiniband` | Required by the Mellanox userspace verbs stack used by the DPDK `mlx5` PMD. |

`/dev/vfio` is not expected to be required for the working Mellanox `mlx5_core` path. The validated Flannel manifest mounted it during testing, so remove it only after confirming your workload still initializes the DPDK port without it. Add it deliberately if your workload uses a true `vfio-pci` model and the NIC is intentionally bound to `vfio-pci`.

## Required Pod Packages

The validated Ubuntu-based pod installs:

```bash
apt-get update
apt-get install -y --no-install-recommends \
  dpdk dpdk-dev iproute2 pciutils rdma-core ibverbs-providers ca-certificates
```

Package purpose:

| Package | Why it is needed |
| --- | --- |
| `dpdk` | Provides DPDK runtime tools and libraries, including `dpdk-testpmd`. A real workload image needs the DPDK runtime libraries required by the application. |
| `dpdk-dev` | Provides DPDK development headers and additional package dependencies. Useful for test images and build-capable images. A production runtime image may not need headers if the app is already built. |
| `iproute2` | Provides the `ip` command for network interface inspection and interface-related setup inside the pod. |
| `pciutils` | Provides `lspci`, useful for confirming the PCI VF is visible inside the pod and mapped to the expected BDF. |
| `rdma-core` | Provides RDMA userspace libraries required by Mellanox devices. The DPDK `mlx5` PMD depends on this userspace stack. |
| `ibverbs-providers` | Provides verbs provider libraries, including the Mellanox provider used by the `mlx5` PMD. |
| `ca-certificates` | Allows HTTPS package downloads and certificate validation in Ubuntu-based images. |

The most important runtime dependencies for this path are:

```text
dpdk
rdma-core
ibverbs-providers
```

The support tools are:

```text
iproute2
pciutils
ca-certificates
```

## Minimal Pod Shape

Replace:

- `10.0.4.108` with the target worker node name.
- `0000:01:00.0` with the secondary VNIC PCI address.
- The command with your actual DPDK application command.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: dpdk-app
  namespace: dpdk-flannel-test
  annotations:
    k8s.v1.cni.cncf.io/networks: dpdk-flannel-test/flannel-dpdk-hostdevice
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: "10.0.4.108"
  tolerations:
  - operator: Exists
  containers:
  - name: dpdk
    image: docker.io/library/ubuntu:22.04
    securityContext:
      privileged: true
      capabilities:
        add:
        - IPC_LOCK
        - SYS_ADMIN
        - NET_ADMIN
        - NET_RAW
    env:
    - name: DEBIAN_FRONTEND
      value: noninteractive
    command:
    - /bin/bash
    - -lc
    - |
      set -euxo pipefail
      apt-get update
      apt-get install -y --no-install-recommends \
        dpdk dpdk-dev iproute2 pciutils rdma-core ibverbs-providers ca-certificates

      dpdk-testpmd \
        -l 0-1 \
        -a 0000:01:00.0 \
        --no-huge \
        --no-telemetry \
        -- \
        --total-num-mbufs=2048 \
        --no-mlockall \
        --auto-start
    resources:
      requests:
        cpu: "1"
        memory: 512Mi
      limits:
        cpu: "1"
        memory: 512Mi
    volumeMounts:
    - name: infiniband
      mountPath: /dev/infiniband
  volumes:
  - name: infiniband
    hostPath:
      path: /dev/infiniband
      type: DirectoryOrCreate
```

## Production Image Guidance

For a production workload, do not install packages with `apt-get` at pod startup.

Instead, build an image that already contains:

- The DPDK application.
- DPDK runtime libraries.
- Mellanox/RDMA userspace libraries from `rdma-core`.
- Verbs providers from `ibverbs-providers`.
- Any application-specific config files or entrypoint scripts.

Keep the Kubernetes pod settings the same:

- Multus `host-device` annotation.
- Node pinning.
- Privileged access or the minimum capabilities proven by your application.
- `/dev/infiniband` host mount.

## Hugepage Requirements

The minimal working test above uses `--no-huge`.

That is the only DPDK path validated on the Flannel cluster in this run. Hugepage-backed DPDK was validated on the VCN-native cluster, but not yet on this Flannel node pool.

If your DPDK application requires hugepages, the worker node must expose hugepage capacity to Kubernetes before the pod is scheduled.

Required additions:

- Configure hugepages during node boot.
- Confirm kubelet advertises hugepage allocatable resources.
- Add pod hugepage requests and limits.
- Mount a hugepage-backed volume.
- Remove `--no-huge` from the DPDK command.

Example pod resource shape:

```yaml
resources:
  requests:
    cpu: "1"
    memory: 512Mi
    hugepages-2Mi: 512Mi
  limits:
    cpu: "1"
    memory: 512Mi
    hugepages-2Mi: 512Mi
volumeMounts:
- name: hugepages
  mountPath: /dev/hugepages
volumes:
- name: hugepages
  emptyDir:
    medium: HugePages
```

Example DPDK command shape:

```bash
dpdk-testpmd \
  -l 0-1 \
  -a 0000:01:00.0 \
  --huge-dir=/dev/hugepages \
  --socket-mem=512 \
  --no-telemetry \
  -- \
  --auto-start
```
