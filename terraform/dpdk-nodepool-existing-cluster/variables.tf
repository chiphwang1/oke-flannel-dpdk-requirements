variable "region" {
  description = "OCI region where the existing OKE cluster runs."
  type        = string
}

variable "oci_profile" {
  description = "OCI CLI config profile used by the OCI Terraform provider."
  type        = string
  default     = "DEFAULT"
}

variable "oci_auth" {
  description = "OCI provider auth mode. Use SecurityToken for local OCI CLI security-token auth."
  type        = string
  default     = "SecurityToken"
}

variable "compartment_id" {
  description = "Compartment OCID for the node pool."
  type        = string
}

variable "cluster_id" {
  description = "Existing OKE cluster OCID."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for the new node pool. Must be supported by the existing cluster."
  type        = string
}

variable "node_pool_name" {
  description = "Name for the DPDK validation node pool."
  type        = string
  default     = "dpdk-hugepages"
}

variable "node_count" {
  description = "Number of worker nodes in the DPDK validation node pool."
  type        = number
  default     = 1
}

variable "node_shape" {
  description = "Compute shape for the DPDK validation node pool."
  type        = string
  default     = "VM.Standard.E5.Flex"
}

variable "ocpus" {
  description = "OCPUs for flexible shapes."
  type        = number
  default     = 4
}

variable "memory_in_gbs" {
  description = "Memory in GB for flexible shapes."
  type        = number
  default     = 32
}

variable "node_image_id" {
  description = "OKE worker image OCID."
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key text to inject into worker nodes."
  type        = string
  sensitive   = true
}

variable "placement_configs" {
  description = "Placement configs for the node pool. Each entry needs an availability domain name and worker-node subnet OCID."
  type = list(object({
    availability_domain = string
    subnet_id           = string
  }))
}

variable "network_launch_type" {
  description = "Network launch type for the node pool. VFIO is used for the OKE SR-IOV/DPDK-capable VM path."
  type        = string
  default     = "VFIO"
}

variable "attach_secondary_vnic" {
  description = "Whether to manually attach one secondary OCI VNIC to each worker instance after OKE creates the node pool."
  type        = bool
  default     = true
}

variable "secondary_vnic_subnet_id" {
  description = "Subnet OCID used for the manually attached secondary VNICs."
  type        = string
  default     = ""
}

variable "secondary_vnic_display_name_prefix" {
  description = "Display-name prefix for manually attached secondary VNICs."
  type        = string
  default     = "dpdk-secondary-vnic"
}

variable "secondary_vnic_assign_public_ip" {
  description = "Whether manually attached secondary VNICs should receive public IPs."
  type        = bool
  default     = false
}

variable "secondary_vnic_skip_source_dest_check" {
  description = "Whether to skip source/destination check on manually attached secondary VNICs."
  type        = bool
  default     = false
}

variable "secondary_vnic_nsg_ids" {
  description = "Optional NSG OCIDs for manually attached secondary VNICs."
  type        = list(string)
  default     = null
}

variable "node_freeform_tags" {
  description = "Freeform tags for the node pool."
  type        = map(string)
  default     = {}
}

variable "node_label_key" {
  description = "Initial Kubernetes label key placed on nodes in this pool for targeting test pods."
  type        = string
  default     = "dpdk.oracle.com/nodepool"
}

variable "test_namespace" {
  description = "Namespace used by rendered DPDK test manifests."
  type        = string
  default     = "dpdk-validation"
}

variable "test_pci_address" {
  description = "PCI BDF to allowlist in testpmd test manifests. Update after inspecting the actual worker node."
  type        = string
  default     = "0000:01:00.0"
}

variable "test_hugepages_2mi" {
  description = "2Mi hugepage request/limit used by rendered test pods."
  type        = string
  default     = "512Mi"
}

variable "test_hugepages_1gi" {
  description = "1Gi hugepage request/limit used by rendered test pods."
  type        = string
  default     = "1Gi"
}
