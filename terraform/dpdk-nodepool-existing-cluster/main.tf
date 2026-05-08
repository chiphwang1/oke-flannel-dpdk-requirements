locals {
  node_labels = {
    (var.node_label_key) = var.node_pool_name
  }

  cloud_init = templatefile("${path.module}/templates/cloud-init-dpdk-hugepages.yaml.tftpl", {
    hugepages_2mi_count = 1024
    hugepages_1gi_count = 1
  })

  node_metadata = {
    areLegacyImdsEndpointsDisabled = "true"
    user_data                      = base64encode(local.cloud_init)
  }

  manifest_vars = {
    namespace        = var.test_namespace
    node_label_key   = var.node_label_key
    node_label_value = var.node_pool_name
    pci_address      = var.test_pci_address
    hugepages_2mi    = var.test_hugepages_2mi
    hugepages_1gi    = var.test_hugepages_1gi
    hostdevice_nad   = "dpdk-hostdevice-pci"
  }
}

resource "oci_containerengine_node_pool" "dpdk" {
  compartment_id      = var.compartment_id
  cluster_id          = var.cluster_id
  kubernetes_version  = var.kubernetes_version
  name                = var.node_pool_name
  node_shape          = var.node_shape
  network_launch_type = var.network_launch_type
  ssh_public_key      = var.ssh_public_key
  freeform_tags       = var.node_freeform_tags
  node_metadata       = local.node_metadata

  node_shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_in_gbs
  }

  node_source_details {
    source_type = "IMAGE"
    image_id    = var.node_image_id
  }

  node_config_details {
    size = var.node_count

    dynamic "placement_configs" {
      for_each = var.placement_configs
      content {
        availability_domain = placement_configs.value.availability_domain
        subnet_id           = placement_configs.value.subnet_id
      }
    }

    node_pool_pod_network_option_details {
      cni_type          = "FLANNEL_OVERLAY"
      max_pods_per_node = var.max_pods_per_node
    }
  }

  initial_node_labels {
    key   = var.node_label_key
    value = var.node_pool_name
  }
}

data "oci_containerengine_node_pool" "dpdk" {
  node_pool_id = oci_containerengine_node_pool.dpdk.id
}

locals {
  worker_instance_ids = [
    for node in data.oci_containerengine_node_pool.dpdk.nodes : node.id
  ]
}

resource "oci_core_vnic_attachment" "secondary" {
  count = var.attach_secondary_vnic ? var.node_count : 0

  instance_id  = local.worker_instance_ids[count.index]
  display_name = "${var.secondary_vnic_display_name_prefix}-${count.index + 1}-attachment"

  create_vnic_details {
    subnet_id              = var.secondary_vnic_subnet_id
    display_name           = "${var.secondary_vnic_display_name_prefix}-${count.index + 1}"
    assign_public_ip       = var.secondary_vnic_assign_public_ip
    skip_source_dest_check = var.secondary_vnic_skip_source_dest_check
    nsg_ids                = var.secondary_vnic_nsg_ids
  }

  lifecycle {
    precondition {
      condition     = trimspace(var.secondary_vnic_subnet_id) != ""
      error_message = "secondary_vnic_subnet_id must be set when attach_secondary_vnic is true."
    }
  }
}

resource "local_file" "namespace_manifest" {
  filename = "${path.module}/rendered-manifests/00-namespace.yaml"
  content  = templatefile("${path.module}/templates/00-namespace.yaml.tftpl", local.manifest_vars)
}

resource "local_file" "hugepages_smoke_manifest" {
  filename = "${path.module}/rendered-manifests/01-hugepages-smoke.yaml"
  content  = templatefile("${path.module}/templates/01-hugepages-smoke.yaml.tftpl", local.manifest_vars)
}

resource "local_file" "hostdevice_multus_manifest" {
  filename = "${path.module}/rendered-manifests/02-flannel-hostdevice-multus-test.yaml"
  content  = templatefile("${path.module}/templates/02-flannel-hostdevice-multus-test.yaml.tftpl", local.manifest_vars)
}
