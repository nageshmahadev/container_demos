# Configure the Azure Provider
# https://github.com/MicrosoftDocs/azure-docs/blob/master/articles/terraform/terraform-create-k8s-cluster-with-tf-and-aks.md

provider "azurerm" {
    subscription_id = "${var.subscription_id}"
    client_id       = "${var.client_id}"
    client_secret   = "${var.client_secret}"
    tenant_id       = "${var.tenant_id}"
}

# https://www.terraform.io/docs/providers/azurerm/d/resource_group.html
resource "azurerm_resource_group" "aksrg" {
  name     = "${var.resource_group_name}"
  location = "${var.location}"
    
  tags {
    Environment = "${var.environment}"
  }
}

# https://www.terraform.io/docs/providers/azurerm/d/network_security_group.html
# resource "azurerm_network_security_group" "aksnsg" {
#   name                = "${var.dns_prefix}-nsg"
#   location            = "${azurerm_resource_group.aksrg.location}"
#   resource_group_name = "${azurerm_resource_group.aksrg.name}"

#   tags {
#     Environment = "${var.environment}"
#   }
# }

# https://www.terraform.io/docs/providers/azurerm/d/virtual_network.html
resource "azurerm_virtual_network" "kubevnet" {
  name                = "${var.dns_prefix}-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = "${azurerm_resource_group.aksrg.location}"
  resource_group_name = "${azurerm_resource_group.aksrg.name}"

  tags {
    Environment = "${var.environment}"
  }
}

# https://www.terraform.io/docs/providers/azurerm/d/subnet.html
resource "azurerm_subnet" "gwnet" {
  name                      = "gw-1-subnet"
  resource_group_name       = "${azurerm_resource_group.aksrg.name}"
  #network_security_group_id = "${azurerm_network_security_group.aksnsg.id}"
  address_prefix            = "10.0.1.0/24"
  virtual_network_name      = "${azurerm_virtual_network.kubevnet.name}"
}
resource "azurerm_subnet" "acinet" {
  name                      = "aci-2-subnet"
  resource_group_name       = "${azurerm_resource_group.aksrg.name}"
  #network_security_group_id = "${azurerm_network_security_group.aksnsg.id}"
  address_prefix            = "10.0.2.0/24"
  virtual_network_name      = "${azurerm_virtual_network.kubevnet.name}"
}
resource "azurerm_subnet" "fwnet" {
  name                      = "AzureFirewallSubnet"
  resource_group_name       = "${azurerm_resource_group.aksrg.name}"
  #network_security_group_id = "${azurerm_network_security_group.aksnsg.id}"
  address_prefix            = "10.0.6.0/24"
  virtual_network_name      = "${azurerm_virtual_network.kubevnet.name}"
}
resource "azurerm_subnet" "ingnet" {
  name                      = "ing-4-subnet"
  resource_group_name       = "${azurerm_resource_group.aksrg.name}"
  #network_security_group_id = "${azurerm_network_security_group.aksnsg.id}"
  address_prefix            = "10.0.4.0/24"
  virtual_network_name      = "${azurerm_virtual_network.kubevnet.name}"
}
resource "azurerm_subnet" "aksnet" {
  name                      = "aks-5-subnet"
  resource_group_name       = "${azurerm_resource_group.aksrg.name}"
  #network_security_group_id = "${azurerm_network_security_group.aksnsg.id}"
  address_prefix            = "10.0.5.0/24"
  virtual_network_name      = "${azurerm_virtual_network.kubevnet.name}"
}

# https://www.terraform.io/docs/providers/azurerm/d/log_analytics_workspace.html
resource "azurerm_log_analytics_workspace" "akslogs" {
  name                = "${var.dns_prefix}-lga"
  location            = "${azurerm_resource_group.aksrg.location}"
  resource_group_name = "${azurerm_resource_group.aksrg.name}"
  sku                 = "Free"
}

resource "azurerm_log_analytics_solution" "akslogs" {
  solution_name         = "ContainerInsights"
  location              = "${azurerm_resource_group.aksrg.location}"
  resource_group_name   = "${azurerm_resource_group.aksrg.name}"
  workspace_resource_id = "${azurerm_log_analytics_workspace.akslogs.id}"
  workspace_name        = "${azurerm_log_analytics_workspace.akslogs.name}"

  plan {
    publisher = "Microsoft"
    product   = "OMSGallery/ContainerInsights"
  }
}

# https://www.terraform.io/docs/providers/azurerm/d/kubernetes_cluster.html
resource "azurerm_kubernetes_cluster" "akstf" {
  name                = "${var.cluster_name}"
  location            = "${azurerm_resource_group.aksrg.location}"
  resource_group_name = "${azurerm_resource_group.aksrg.name}"
  dns_prefix          = "${var.dns_prefix}"
  kubernetes_version  = "${var.kubernetes_version}"

  linux_profile {
    admin_username = "dennis"

    ssh_key {
      key_data = "${file("${var.ssh_public_key}")}"
    }
  }

  agent_pool_profile {
    name            = "default"
    count           =  "${var.agent_count}"
    vm_size         = "Standard_DS2_v2"
    os_type         = "Linux"
    os_disk_size_gb = 30
    vnet_subnet_id = "${azurerm_subnet.aksnet.id}"
  }

  role_based_access_control {
    enabled        = true
  }

  network_profile {
      network_plugin = "kubenet"
      service_cidr   = "10.2.0.0/24"
      dns_service_ip = "10.2.0.10"
      docker_bridge_cidr = "172.17.0.1/16"
      # pod_cidr = "" selected by subnetid
  }

  service_principal {
    client_id     = "${var.client_id}"
    client_secret = "${var.client_secret}"
  }

  addon_profile {
    oms_agent {
      enabled                    = true
      log_analytics_workspace_id = "${azurerm_log_analytics_workspace.akslogs.id}"
    }
  }

  tags {
    Environment = "${var.environment}"
  }
}

# this is needed to fix https://github.com/Azure/AKS/issues/718
resource "null_resource" "fix_routetable" {
  provisioner "local-exec" {
    command = "az network vnet subnet update -n ${azurerm_subnet.aksnet.name} -g ${azurerm_resource_group.aksrg.name} --vnet-name ${azurerm_virtual_network.kubevnet.name} --route-table $(az resource list --resource-group MC_${azurerm_resource_group.aksrg.name}_${azurerm_kubernetes_cluster.akstf.name}_${azurerm_resource_group.aksrg.location} --resource-type Microsoft.Network/routeTables --query '[].{ID:id}' -o tsv)"
  }
  depends_on = ["azurerm_kubernetes_cluster.akstf"]
}

output "id" {
    value = "${azurerm_kubernetes_cluster.akstf.id}"
}

output "kube_config" {
  value = "${azurerm_kubernetes_cluster.akstf.kube_config_raw}"
}

output "client_key" {
  value = "${azurerm_kubernetes_cluster.akstf.kube_config.0.client_key}"
}

output "client_certificate" {
  value = "${azurerm_kubernetes_cluster.akstf.kube_config.0.client_certificate}"
}

output "cluster_ca_certificate" {
  value = "${azurerm_kubernetes_cluster.akstf.kube_config.0.cluster_ca_certificate}"
}

output "host" {
  value = "${azurerm_kubernetes_cluster.akstf.kube_config.0.host}"
}