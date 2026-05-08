output "node_pool_id" {
  description = "Created OKE node pool OCID."
  value       = oci_containerengine_node_pool.dpdk.id
}

output "node_pool_name" {
  description = "Created OKE node pool name."
  value       = oci_containerengine_node_pool.dpdk.name
}

output "node_selector" {
  description = "Node selector used by the rendered test pods."
  value       = local.node_labels
}

output "worker_instance_ids" {
  description = "Compute instance OCIDs for nodes in the created node pool."
  value       = sort(local.worker_instance_ids)
}

output "secondary_vnic_attachment_ids" {
  description = "Manual secondary VNIC attachment OCIDs."
  value       = [for attachment in oci_core_vnic_attachment.secondary : attachment.id]
}

output "secondary_vnic_ids" {
  description = "Manual secondary VNIC OCIDs."
  value       = [for attachment in oci_core_vnic_attachment.secondary : attachment.vnic_id]
}

output "rendered_manifest_files" {
  description = "Rendered Kubernetes manifests for DPDK validation."
  value = [
    local_file.namespace_manifest.filename,
    local_file.hugepages_smoke_manifest.filename,
    local_file.hostdevice_multus_manifest.filename,
  ]
}

output "next_commands" {
  description = "Suggested validation commands after the node joins the cluster."
  value = [
    "kubectl get nodes -l ${var.node_label_key}=${var.node_pool_name} -o wide",
    "kubectl get nodes -l ${var.node_label_key}=${var.node_pool_name} -o json | jq '.items[].status.allocatable'",
    "kubectl apply -f ${path.module}/rendered-manifests/00-namespace.yaml",
    "kubectl apply -f ${path.module}/rendered-manifests/01-hugepages-smoke.yaml",
    "kubectl -n ${var.test_namespace} logs -f dpdk-hugepages-smoke",
    "kubectl apply -f ${path.module}/rendered-manifests/02-flannel-hostdevice-multus-test.yaml",
    "kubectl -n ${var.test_namespace} get pod dpdk-flannel-hostdevice-test -o jsonpath='{.metadata.annotations.k8s\\.v1\\.cni\\.cncf\\.io/network-status}'",
    "kubectl -n ${var.test_namespace} logs -f dpdk-flannel-hostdevice-test",
  ]
}
