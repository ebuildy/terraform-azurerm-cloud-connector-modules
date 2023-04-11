################################################################################
# Generate a unique random string for resource name assignment and key pair
################################################################################
resource "random_string" "suffix" {
  length  = 8
  upper   = false
  special = false
}


################################################################################
# Map default tags with values to be assigned to all tagged resources
################################################################################
locals {
  global_tags = {
    Owner       = var.owner_tag
    ManagedBy   = "terraform"
    Vendor      = "Zscaler"
    Environment = var.environment
  }
}


################################################################################
# The following lines generates a new SSH key pair and stores the PEM file 
# locally. The public key output is used as the instance_key passed variable 
# to the vm modules for admin_ssh_key public_key authentication.
# This is not recommended for production deployments. Please consider modifying 
# to pass your own custom public key file located in a secure location.   
################################################################################
# private key for login
resource "tls_private_key" "key" {
  algorithm = var.tls_key_algorithm
}

# write private key to local pem file
resource "local_file" "private_key" {
  content         = tls_private_key.key.private_key_pem
  filename        = "../${var.name_prefix}-key-${random_string.suffix.result}.pem"
  file_permission = "0600"
}


################################################################################
# 1. Create/reference all network infrastructure resource dependencies for all 
#    child modules (Resource Group, VNet, Subnets, NAT Gateway, Route Tables)
################################################################################
module "network" {
  source                = "../../modules/terraform-zscc-network-azure"
  name_prefix           = var.name_prefix
  resource_tag          = random_string.suffix.result
  global_tags           = local.global_tags
  location              = var.arm_location
  network_address_space = var.network_address_space
  cc_subnets            = var.cc_subnets
  workloads_subnets     = var.workloads_subnets
  public_subnets        = var.public_subnets
  private_dns_subnet    = var.private_dns_subnet
  zones_enabled         = var.zones_enabled
  zones                 = var.zones
  cc_service_ip         = module.cc_vm.service_ip
  workloads_enabled     = true
  bastion_enabled       = true
  lb_enabled            = var.lb_enabled
  zpa_enabled           = var.zpa_enabled
}


################################################################################
# 2. Create Bastion Host for workload and CC SSH jump access
################################################################################
module "bastion" {
  source                    = "../../modules/terraform-zscc-bastion-azure"
  location                  = var.arm_location
  name_prefix               = var.name_prefix
  resource_tag              = random_string.suffix.result
  global_tags               = local.global_tags
  resource_group            = module.network.resource_group_name
  public_subnet_id          = module.network.bastion_subnet_ids[0]
  ssh_key                   = tls_private_key.key.public_key_openssh
  bastion_nsg_source_prefix = var.bastion_nsg_source_prefix
}


################################################################################
# 3. Create Workload Hosts to test traffic connectivity through CC
################################################################################
module "workload" {
  source         = "../../modules/terraform-zscc-workload-azure"
  workload_count = var.workload_count
  location       = var.arm_location
  name_prefix    = var.name_prefix
  resource_tag   = random_string.suffix.result
  global_tags    = local.global_tags
  resource_group = module.network.resource_group_name
  subnet_id      = module.network.workload_subnet_ids[0]
  ssh_key        = tls_private_key.key.public_key_openssh
  dns_servers    = []
}


################################################################################
# 4. Create specified number of CC VMs per cc_count by default in an
#    availability set for Azure Data Center fault tolerance. Optionally, deployed
#    CCs can automatically span equally across designated availabilty zones 
#    if enabled via "zones_enabled" and "zones" variables. E.g. cc_count set to 
#    4 and 2 zones ['1","2"] will create 2x CCs in AZ1 and 2x CCs in AZ2
################################################################################
# Create the user_data file with necessary bootstrap variables for Cloud Connector registration
locals {
  userdata = <<USERDATA
[ZSCALER]
CC_URL=${var.cc_vm_prov_url}
AZURE_VAULT_URL=${var.azure_vault_url}
HTTP_PROBE_PORT=${var.http_probe_port}
USERDATA
}

# Write the file to local filesystem for storage/reference
resource "local_file" "user_data_file" {
  content  = local.userdata
  filename = "../user_data"
}

# Create specified number of CC appliances
module "cc_vm" {
  source                         = "../../modules/terraform-zscc-ccvm-azure"
  name_prefix                    = var.name_prefix
  resource_tag                   = random_string.suffix.result
  global_tags                    = local.global_tags
  resource_group                 = module.network.resource_group_name
  mgmt_subnet_id                 = module.network.cc_subnet_ids
  service_subnet_id              = module.network.cc_subnet_ids
  ssh_key                        = tls_private_key.key.public_key_openssh
  managed_identity_id            = module.cc_identity.managed_identity_id
  user_data                      = local.userdata
  location                       = var.arm_location
  zones_enabled                  = var.zones_enabled
  zones                          = var.zones
  ccvm_instance_type             = var.ccvm_instance_type
  ccvm_image_publisher           = var.ccvm_image_publisher
  ccvm_image_offer               = var.ccvm_image_offer
  ccvm_image_sku                 = var.ccvm_image_sku
  ccvm_image_version             = var.ccvm_image_version
  cc_instance_size               = var.cc_instance_size
  mgmt_nsg_id                    = module.cc_nsg.mgmt_nsg_id
  service_nsg_id                 = module.cc_nsg.service_nsg_id
  accelerated_networking_enabled = var.accelerated_networking_enabled

  depends_on = [
    local_file.user_data_file,
    null_resource.cc_error_checker,
  ]
}


################################################################################
# 5. Create Network Security Group and rules to be assigned to CC mgmt and 
#    service interface(s). Default behavior will create 1 of each resource per
#    CC VM. Set variable "reuse_nsg" to true if you would like a single NSG 
#    created and assigned to ALL Cloud Connectors
################################################################################
module "cc_nsg" {
  source         = "../../modules/terraform-zscc-nsg-azure"
  nsg_count      = var.reuse_nsg == false ? var.cc_count : 1
  name_prefix    = var.name_prefix
  resource_tag   = random_string.suffix.result
  resource_group = module.network.resource_group_name
  location       = var.arm_location
  global_tags    = local.global_tags
}


################################################################################
# 6. Reference User Managed Identity resource to obtain ID to be assigned to 
#    all Cloud Connectors 
################################################################################
module "cc_identity" {
  source                      = "../../modules/terraform-zscc-identity-azure"
  cc_vm_managed_identity_name = var.cc_vm_managed_identity_name
  cc_vm_managed_identity_rg   = var.cc_vm_managed_identity_rg

  #optional variable provider block defined in versions.tf to support managed identity resource being in a different subscription
  providers = {
    azurerm = azurerm.managed_identity_sub
  }
}


################################################################################
# 7. Create Azure Private DNS Resolver Ruleset, Rules, and Outbound Endpoint
#    for utilization with DNS redirection/conditional forwarding to Cloud
#    Connector to enabling ZPA and/or ZIA DNS control features.
################################################################################
module "private_dns" {
  source                = "../../modules/terraform-zscc-private-dns-azure"
  name_prefix           = var.name_prefix
  resource_tag          = random_string.suffix.result
  global_tags           = local.global_tags
  resource_group        = module.network.resource_group_name
  location              = var.arm_location
  vnet_id               = module.network.virtual_network_id
  private_dns_subnet_id = module.network.private_dns_subnet_id
  domain_names          = var.domain_names
  target_address        = var.target_address
}

################################################################################
# Optional: Create Azure Private DNS Resolver Virtual Network Link
# This resource is getting created for greenfield deployments since
# workloads are being deployed in the same VNet as the Cloud Connectors.

# Generally, this would only be created and associated with spoke VNets in
# centralized hub-spoke topologies. Be careful what domains are used in rule
# creation to avoid DNS loops.
################################################################################
resource "azurerm_private_dns_resolver_virtual_network_link" "dns_vnet_link" {
  name                      = "${var.name_prefix}-vnet-link-${random_string.suffix.result}"
  dns_forwarding_ruleset_id = module.private_dns.private_dns_forwarding_ruleset_id
  virtual_network_id        = module.network.virtual_network_id
}


################################################################################
# Validation for Cloud Connector instance size and VM Instance Type 
# compatibilty. Terraform does not have a good/native way to raise an error at 
# the moment, so this will trigger off an invalid count value if there is an 
# improper deployment configuration.
################################################################################
resource "null_resource" "cc_error_checker" {
  count = local.valid_cc_create ? 0 : "Cloud Connector parameters were invalid. No appliances were created. Please check the documentation and cc_instance_size / ccvm_instance_type values that were chosen" # 0 means no error is thrown, else throw error
  provisioner "local-exec" {
    command = <<EOF
      echo "Cloud Connector parameters were invalid. No appliances were created. Please check the documentation and cc_instance_size / ccvm_instance_type values that were chosen" >> ../errorlog.txt
EOF
  }
}
