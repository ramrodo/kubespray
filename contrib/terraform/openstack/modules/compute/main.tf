data "openstack_networking_secgroup_v2" "default" {
  name = "default"
}

data "openstack_networking_subnet_v2" "k8s_network_subnet" {
  subnet_id  = "${var.vip_subnet_id}"
}

resource "openstack_compute_keypair_v2" "k8s" {
  name       = "kubernetes-${var.cluster_name}"
  public_key = "${chomp(file(var.public_key_path))}"
}

resource "openstack_networking_secgroup_v2" "k8s_master" {
  name        = "${var.cluster_name}-k8s-master"
  description = "${var.cluster_name} - Kubernetes Master"
}

resource "openstack_networking_secgroup_rule_v2" "k8s_master" {
  direction = "ingress"
  ethertype = "IPv4"
  protocol = "tcp"
  port_range_min = "6443"
  port_range_max = "6443"
  remote_ip_prefix = "0.0.0.0/0"
  security_group_id = "${openstack_networking_secgroup_v2.k8s_master.id}"
}

resource "openstack_networking_secgroup_v2" "bastion" {
  name        = "${var.cluster_name}-bastion"
  description = "${var.cluster_name} - Bastion Server"
}

resource "openstack_networking_secgroup_rule_v2" "bastion" {
  count = "${length(var.bastion_allowed_remote_ips)}"
  direction = "ingress"
  ethertype = "IPv4"
  protocol = "tcp"
  port_range_min = "22"
  port_range_max = "22"
  remote_ip_prefix = "${var.bastion_allowed_remote_ips[count.index]}"
  security_group_id = "${openstack_networking_secgroup_v2.bastion.id}"
}

resource "openstack_networking_secgroup_v2" "k8s-global" {
  name        = "${var.cluster_name}-k8s-global"
  description = "${var.cluster_name} - Kubernetes"
}

resource "openstack_networking_secgroup_rule_v2" "icmp" {
  direction = "ingress"
  ethertype = "IPv4"
  protocol = "icmp"
  remote_ip_prefix = "0.0.0.0/0"
  security_group_id = "${openstack_networking_secgroup_v2.k8s-global.id}"
}

resource "openstack_networking_secgroup_v2" "k8s" {
  name        = "${var.cluster_name}-k8s"
  description = "${var.cluster_name} - Kubernetes"
}

resource "openstack_networking_secgroup_rule_v2" "k8s" {
  direction = "ingress"
  ethertype = "IPv4"
  remote_group_id = "${openstack_networking_secgroup_v2.k8s.id}"
  security_group_id = "${openstack_networking_secgroup_v2.k8s.id}"
}

resource "openstack_networking_secgroup_v2" "worker" {
  name        = "${var.cluster_name}-k8s-worker"
  description = "${var.cluster_name} - Kubernetes worker nodes"
}

resource "openstack_networking_secgroup_rule_v2" "worker" {
  count = "${length(var.worker_allowed_ports)}"
  direction = "ingress"
  ethertype = "IPv4"
  protocol = "${lookup(var.worker_allowed_ports[count.index], "protocol", "tcp")}"
  port_range_min = "${lookup(var.worker_allowed_ports[count.index], "port_range_min")}"
  port_range_max = "${lookup(var.worker_allowed_ports[count.index], "port_range_max")}"
  remote_ip_prefix = "${lookup(var.worker_allowed_ports[count.index], "remote_ip_prefix", "0.0.0.0/0")}"
  security_group_id = "${openstack_networking_secgroup_v2.worker.id}"
}

resource "openstack_compute_servergroup_v2" "etcd_aa_group" {
  count    = "${var.etcd_anti_affinity == "true" ? 1 : 0}"
  name     = "${var.cluster_name}-etcd-group"
  policies = ["anti-affinity"]
}

resource "openstack_compute_servergroup_v2" "master_aa_group" {
  count    = "${var.master_anti_affinity == "true" ? 1 : 0}"
  name     = "${var.cluster_name}-master-group"
  policies = ["anti-affinity"]
}

resource "openstack_compute_instance_v2" "bastion" {
  name       = "${var.cluster_name}-bastion-${count.index+1}"
  count      = "${var.number_of_bastions}"
  image_name = "${var.image}"
  flavor_id  = "${var.flavor_bastion}"
  key_pair   = "${openstack_compute_keypair_v2.k8s.name}"
  user_data  = "${var.openstack_user_data}"
  lifecycle {
    ignore_changes = ["user_data"]
  }

  depends_on = [
    "data.openstack_networking_subnet_v2.k8s_network_subnet"
  ]

  network {
    name = "${var.network_name}"
  }

  security_groups = ["${openstack_networking_secgroup_v2.k8s.name}",
    "${openstack_networking_secgroup_v2.bastion.name}",
    "default",
  ]

  metadata = {
    ssh_user         = "${var.ssh_user}"
    kubespray_groups = "bastion" # use of kubespray_groups is deprecated; use 'groups' instead
    groups = "bastion"
  }

  provisioner "local-exec" {
    command = "sed s/USER/${var.ssh_user}/ ${var.kubespray_dir}/contrib/terraform/openstack/ansible_bastion_template.txt | sed s/BASTION_ADDRESS/${var.bastion_fips[0]}/ > ${var.inventory_dir}/group_vars/no-floating.yml"
  }

}

resource "openstack_compute_instance_v2" "k8s_master" {
  name       = "${var.cluster_name}-k8s-master-${count.index+1}"
  count      = "${var.number_of_k8s_masters}"
  availability_zone = "${element(var.az_list, count.index)}"
  image_name = "${var.image}"
  flavor_id  = "${var.flavor_k8s_master}"
  key_pair   = "${openstack_compute_keypair_v2.k8s.name}"
  user_data  = "${var.openstack_user_data}"
  lifecycle {
    ignore_changes = ["user_data"]
  }

  depends_on = [
    "data.openstack_networking_subnet_v2.k8s_network_subnet"
  ]

  network {
    name = "${var.network_name}"
  }

  scheduler_hints {
    group = "${join("", openstack_compute_servergroup_v2.master_aa_group.*.id)}"
  }

  security_groups = ["${openstack_networking_secgroup_v2.k8s_master.name}",
    "${openstack_networking_secgroup_v2.bastion.name}",
    "${openstack_networking_secgroup_v2.k8s.name}",
    "${openstack_networking_secgroup_v2.k8s-global.name}",
    "default",
  ]

  metadata = {
    ssh_user         = "${var.ssh_user}"
    kubespray_groups = "etcd,kube-master,${var.supplementary_master_groups},k8s-cluster,vault" # use of kubespray_groups is deprecated; use 'groups' instead
    groups = "etcd,kube-master,${var.supplementary_master_groups},k8s-cluster,vault"
  }

  provisioner "local-exec" {
    command = "sed s/USER/${var.ssh_user}/ ${var.kubespray_dir}/contrib/terraform/openstack/ansible_bastion_template.txt | sed s/BASTION_ADDRESS/${element( concat(var.bastion_fips, var.k8s_master_fips), 0)}/ > ${var.inventory_dir}/group_vars/no-floating.yml"
  }

}

resource "openstack_networking_port_v2" "k8s_master_no_etcd" {
  name           = "port_1"
  count          = "${var.number_of_k8s_masters_no_etcd}"
  admin_state_up = "true"
  network_id     = "${var.real_network_id}"

  depends_on = [
    "data.openstack_networking_subnet_v2.k8s_network_subnet"
  ]

  security_group_ids = ["${openstack_networking_secgroup_v2.k8s_master.id}",
    "${openstack_networking_secgroup_v2.bastion.id}",
    "${openstack_networking_secgroup_v2.k8s.id}",
    "${openstack_networking_secgroup_v2.k8s-global.id}",
    "${data.openstack_networking_secgroup_v2.default.id}",
  ]

  allowed_address_pairs = [
    { ip_address = "${var.service_cidr}" },
    { ip_address = "${var.cluster_cidr}" },
  ]
}

resource "openstack_compute_instance_v2" "k8s_master_no_etcd" {
  name       = "${var.cluster_name}-k8s-master-ne-${count.index+1}"
  count      = "${var.number_of_k8s_masters_no_etcd}"
  availability_zone = "${element(var.az_list, count.index)}"
  image_name = "${var.image}"
  flavor_id  = "${var.flavor_k8s_master}"
  key_pair   = "${openstack_compute_keypair_v2.k8s.name}"
  user_data  = "${var.openstack_user_data}"
  lifecycle {
    ignore_changes = ["user_data"]
  }

  depends_on = [
    "openstack_networking_port_v2.k8s_master_no_etcd"
  ]

  network {
    port = "${element(openstack_networking_port_v2.k8s_master_no_etcd.*.id, count.index)}"
  }

  scheduler_hints {
    group = "${join("", openstack_compute_servergroup_v2.master_aa_group.*.id)}"
  }

  metadata = {
    ssh_user         = "${var.ssh_user}"
    kubespray_groups = "kube-master,${var.supplementary_master_groups},k8s-cluster,vault" # use of kubespray_groups is deprecated; use 'groups' instead
    groups = "kube-master,${var.supplementary_master_groups},k8s-cluster,vault"
  }

  provisioner "local-exec" {
    command = "sed s/USER/${var.ssh_user}/ ${var.kubespray_dir}/contrib/terraform/openstack/ansible_bastion_template.txt | sed s/BASTION_ADDRESS/${element( concat(var.bastion_fips, var.k8s_master_no_etcd_fips), 0)}/ > ${var.inventory_dir}/group_vars/no-floating.yml"
  }

}

resource "openstack_compute_instance_v2" "etcd" {
  name       = "${var.cluster_name}-etcd-${count.index+1}"
  count      = "${var.number_of_etcd}"
  availability_zone = "${element(var.az_list, count.index)}"
  image_name = "${var.image}"
  flavor_id  = "${var.flavor_etcd}"
  key_pair   = "${openstack_compute_keypair_v2.k8s.name}"
  user_data  = "${var.openstack_user_data}"
  lifecycle {
    ignore_changes = ["user_data"]
  }

  depends_on = [
    "data.openstack_networking_subnet_v2.k8s_network_subnet"
  ]

  network {
    name = "${var.network_name}"
  }

  scheduler_hints {
    group = "${join("", openstack_compute_servergroup_v2.etcd_aa_group.*.id)}"
  }

  security_groups = ["${openstack_networking_secgroup_v2.k8s.name}",
    "${openstack_networking_secgroup_v2.k8s-global.name}",
  ]

  metadata = {
    ssh_user         = "${var.ssh_user}"
    kubespray_groups = "etcd,vault,no-floating" # use of kubespray_groups is deprecated; use 'groups' instead
    groups = "etcd,vault,no-floating"
  }

}

resource "openstack_compute_instance_v2" "k8s_master_no_floating_ip" {
  name       = "${var.cluster_name}-k8s-master-nf-${count.index+1}"
  count      = "${var.number_of_k8s_masters_no_floating_ip}"
  availability_zone = "${element(var.az_list, count.index)}"
  image_name = "${var.image}"
  flavor_id  = "${var.flavor_k8s_master}"
  key_pair   = "${openstack_compute_keypair_v2.k8s.name}"
  user_data  = "${var.openstack_user_data}"
  lifecycle {
    ignore_changes = ["user_data"]
  }

  depends_on = [
    "data.openstack_networking_subnet_v2.k8s_network_subnet"
  ]

  network {
    name = "${var.network_name}"
  }

  scheduler_hints {
    group = "${join("", openstack_compute_servergroup_v2.master_aa_group.*.id)}"
  }

  security_groups = ["${openstack_networking_secgroup_v2.k8s_master.name}",
    "${openstack_networking_secgroup_v2.k8s.name}",
    "${openstack_networking_secgroup_v2.k8s-global.name}",
    "default",
  ]

  metadata = {
    ssh_user         = "${var.ssh_user}"
    kubespray_groups = "etcd,kube-master,${var.supplementary_master_groups},k8s-cluster,vault,no-floating" # use of kubespray_groups is deprecated; use 'groups' instead
    groups = "etcd,kube-master,${var.supplementary_master_groups},k8s-cluster,vault,no-floating"
  }

}

resource "openstack_compute_instance_v2" "k8s_master_no_floating_ip_no_etcd" {
  name       = "${var.cluster_name}-k8s-master-ne-nf-${count.index+1}"
  count      = "${var.number_of_k8s_masters_no_floating_ip_no_etcd}"
  availability_zone = "${element(var.az_list, count.index)}"
  image_name = "${var.image}"
  flavor_id  = "${var.flavor_k8s_master}"
  key_pair   = "${openstack_compute_keypair_v2.k8s.name}"
  user_data  = "${var.openstack_user_data}"
  lifecycle {
    ignore_changes = ["user_data"]
  }

  depends_on = [
    "data.openstack_networking_subnet_v2.k8s_network_subnet"
  ]

  network {
    name = "${var.network_name}"
  }

  scheduler_hints {
    group = "${join("", openstack_compute_servergroup_v2.master_aa_group.*.id)}"
  }

  security_groups = ["${openstack_networking_secgroup_v2.k8s_master.name}",
    "${openstack_networking_secgroup_v2.k8s.name}",
    "${openstack_networking_secgroup_v2.k8s-global.name}",
  ]

  metadata = {
    ssh_user         = "${var.ssh_user}"
    kubespray_groups = "kube-master,${var.supplementary_master_groups},k8s-cluster,vault,no-floating" # use of kubespray_groups is deprecated; use 'groups' instead
    groups = "kube-master,${var.supplementary_master_groups},k8s-cluster,vault,no-floating"
  }

}

resource "openstack_compute_instance_v2" "k8s_node" {
  name       = "${var.cluster_name}-k8s-node-${count.index+1}"
  count      = "${var.number_of_k8s_nodes}"
  availability_zone = "${element(var.az_list, count.index)}"
  image_name = "${var.image}"
  flavor_id  = "${var.flavor_k8s_node}"
  key_pair   = "${openstack_compute_keypair_v2.k8s.name}"
  user_data  = "${var.openstack_user_data}"
  lifecycle {
    ignore_changes = ["user_data"]
  }

  depends_on = [
    "data.openstack_networking_subnet_v2.k8s_network_subnet"
  ]

  network {
    name = "${var.network_name}"
  }

  security_groups = ["${openstack_networking_secgroup_v2.k8s.name}",
    "${openstack_networking_secgroup_v2.bastion.name}",
    "${openstack_networking_secgroup_v2.worker.name}",
    "${openstack_networking_secgroup_v2.k8s-global.name}",
    "default",
  ]

  metadata = {
    ssh_user         = "${var.ssh_user}"
    kubespray_groups = "kube-node,k8s-cluster,${var.supplementary_node_groups}" # use of kubespray_groups is deprecated; use 'groups' instead
    groups = "kube-node,k8s-cluster,${var.supplementary_node_groups}"
  }

  provisioner "local-exec" {
    command = "sed s/USER/${var.ssh_user}/ contrib/terraform/openstack/ansible_bastion_template.txt | sed s/BASTION_ADDRESS/${element( concat(var.bastion_fips, var.k8s_node_fips), 0)}/ > contrib/terraform/group_vars/no-floating.yml"
  }

}

resource "openstack_networking_port_v2" "k8s_node_no_floating_ip" {
  name           = "port_1"
  count          = "${var.number_of_k8s_nodes_no_floating_ip}"
  admin_state_up = "true"
  network_id     = "${var.real_network_id}"

  depends_on = [
    "data.openstack_networking_subnet_v2.k8s_network_subnet"
  ]

  security_group_ids = ["${openstack_networking_secgroup_v2.k8s.id}",
    "${openstack_networking_secgroup_v2.worker.id}",
    "${openstack_networking_secgroup_v2.k8s-global.id}",
    "${data.openstack_networking_secgroup_v2.default.id}",
  ]

  allowed_address_pairs = [
    { ip_address = "${var.service_cidr}" },
    { ip_address = "${var.cluster_cidr}" },
  ]
}

resource "openstack_compute_instance_v2" "k8s_node_no_floating_ip" {
  name       = "${var.cluster_name}-k8s-node-nf-${count.index+1}"
  count      = "${var.number_of_k8s_nodes_no_floating_ip}"
  availability_zone = "${element(var.az_list, count.index)}"
  image_name = "${var.image}"
  flavor_id  = "${var.flavor_k8s_node}"
  key_pair   = "${openstack_compute_keypair_v2.k8s.name}"
  user_data  = "${var.openstack_user_data}"
  lifecycle {
    ignore_changes = ["user_data"]
  }

  depends_on = [
    "openstack_networking_port_v2.k8s_node_no_floating_ip"
  ]

  network {
    port = "${element(openstack_networking_port_v2.k8s_node_no_floating_ip.*.id, count.index)}"
  }

  metadata = {
    ssh_user         = "${var.ssh_user}"
    kubespray_groups = "kube-node,k8s-cluster,no-floating,${var.supplementary_node_groups}" # use of kubespray_groups is deprecated; use 'groups' instead
    groups = "kube-node,k8s-cluster,no-floating,${var.supplementary_node_groups}"
  }

}

resource "openstack_compute_floatingip_associate_v2" "bastion" {
  count       = "${var.number_of_bastions}"
  floating_ip = "${var.bastion_fips[count.index]}"
  instance_id = "${element(openstack_compute_instance_v2.bastion.*.id, count.index)}"
}

resource "openstack_compute_floatingip_associate_v2" "k8s_master" {
  count       = "${var.number_of_k8s_masters}"
  instance_id = "${element(openstack_compute_instance_v2.k8s_master.*.id, count.index)}"
  floating_ip = "${var.k8s_master_fips[count.index]}"
}

resource "openstack_compute_floatingip_associate_v2" "k8s_master_no_etcd" {
  count       = "${var.number_of_k8s_masters_no_etcd}"
  instance_id = "${element(openstack_compute_instance_v2.k8s_master_no_etcd.*.id, count.index)}"
  floating_ip = "${var.k8s_master_no_etcd_fips[count.index]}"
}

resource "openstack_compute_floatingip_associate_v2" "k8s_node" {
  count       = "${var.number_of_k8s_nodes}"
  floating_ip = "${var.k8s_node_fips[count.index]}"
  instance_id = "${element(openstack_compute_instance_v2.k8s_node.*.id, count.index)}"
}

resource "openstack_blockstorage_volume_v2" "glusterfs_volume" {
  name        = "${var.cluster_name}-glusterfs_volume-${count.index+1}"
  count       = "${var.number_of_gfs_nodes_no_floating_ip}"
  description = "Non-ephemeral volume for GlusterFS"
  size        = "${var.gfs_volume_size_in_gb}"
}

resource "openstack_compute_instance_v2" "glusterfs_node_no_floating_ip" {
  name       = "${var.cluster_name}-gfs-node-nf-${count.index+1}"
  count      = "${var.number_of_gfs_nodes_no_floating_ip}"
  availability_zone = "${element(var.az_list, count.index)}"
  image_name = "${var.image_gfs}"
  flavor_id  = "${var.flavor_gfs_node}"
  key_pair   = "${openstack_compute_keypair_v2.k8s.name}"
  user_data  = "${var.openstack_user_data}"

  depends_on = [
    "data.openstack_networking_subnet_v2.k8s_network_subnet"
  ]

  network {
    name = "${var.network_name}"
  }

  security_groups = ["${openstack_networking_secgroup_v2.k8s.name}",
    "${openstack_networking_secgroup_v2.k8s-global.name}",
    "default",
  ]

  metadata = {
    ssh_user         = "${var.ssh_user_gfs}"
    kubespray_groups = "gfs-cluster,network-storage,no-floating" # use of kubespray_groups is deprecated; use 'groups' instead
    groups = "gfs-cluster,network-storage,no-floating"
  }

}

resource "openstack_compute_volume_attach_v2" "glusterfs_volume" {
  count       = "${var.number_of_gfs_nodes_no_floating_ip}"
  instance_id = "${element(openstack_compute_instance_v2.glusterfs_node_no_floating_ip.*.id, count.index)}"
  volume_id   = "${element(openstack_blockstorage_volume_v2.glusterfs_volume.*.id, count.index)}"
}
