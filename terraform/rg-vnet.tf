############################
# Resource Group
############################

resource "azurerm_resource_group" "ha_rg" {
  name     = "rg-ha-eastus"
  location = "East US"
}

resource "azurerm_resource_group" "dr_rg" {
  name     = "rg-dr-westus"
  location = "West US"
}

############################
# Virtual Network
############################

resource "azurerm_virtual_network" "ha_vnet" {
  name                = "ha-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.ha_rg.location
  resource_group_name = azurerm_resource_group.ha_rg.name
}

resource "azurerm_subnet" "ha_subnet" {
  name                 = "ha-subnet"
  resource_group_name  = azurerm_resource_group.ha_rg.name
  virtual_network_name = azurerm_virtual_network.ha_vnet.name
  address_prefixes     = ["10.0.0.0/24"]
}

resource "azurerm_virtual_network" "dr_vnet" {
  name                = "dr-vnet"
  address_space       = ["10.1.0.0/16"]
  location            = azurerm_resource_group.dr_rg.location
  resource_group_name = azurerm_resource_group.dr_rg.name
}

resource "azurerm_subnet" "dr_subnet" {
  name                 = "dr-subnet"
  resource_group_name  = azurerm_resource_group.dr_rg.name
  virtual_network_name = azurerm_virtual_network.dr_vnet.name
  address_prefixes     = ["10.1.0.0/24"]
}

############################
# Peering
############################

resource "azurerm_virtual_network_peering" "ha_to_dr" {
  name                         = "peerhatoda"
  resource_group_name          = azurerm_resource_group.ha_rg.name
  virtual_network_name         = azurerm_virtual_network.ha_vnet.name
  remote_virtual_network_id    = azurerm_virtual_network.dr_vnet.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

resource "azurerm_virtual_network_peering" "dr_to_ha" {
  name                         = "peerdrtoha"
  resource_group_name          = azurerm_resource_group.dr_rg.name
  virtual_network_name         = azurerm_virtual_network.dr_vnet.name
  remote_virtual_network_id    = azurerm_virtual_network.ha_vnet.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}