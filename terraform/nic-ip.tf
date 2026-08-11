############################
# Public IPs
############################

resource "azurerm_public_ip" "pip" {
  name                = "vm-haproxy-ha-pip"
  location            = azurerm_resource_group.ha_rg.location
  resource_group_name = azurerm_resource_group.ha_rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_public_ip" "pip2" {
  name                = "vm-haproxy-dr-pip"
  location            = azurerm_resource_group.dr_rg.location
  resource_group_name = azurerm_resource_group.dr_rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_public_ip" "pip3" {
  name                = "vm-monitoring-ha-pip"
  location            = azurerm_resource_group.ha_rg.location
  resource_group_name = azurerm_resource_group.ha_rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_public_ip" "pip4" {
  name                = "vm-monitoring-dr-pip"
  location            = azurerm_resource_group.dr_rg.location
  resource_group_name = azurerm_resource_group.dr_rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

############################
# Network Security Group
############################

resource "azurerm_network_security_group" "ha_nsg" {
  name                = "ha-nsg"
  location            = azurerm_resource_group.ha_rg.location
  resource_group_name = azurerm_resource_group.ha_rg.name

  security_rule {
    name                       = "AllowSSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "AllowHTTP"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowHTTPS"
    priority                   = 1003
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowGrafana"
    priority                   = 1004
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3000"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowPrometheus"
    priority                   = 1005
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "9090"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowAlertmanager"
    priority                   = 1006
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "9093"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "ha_subnet_nsg" {
  subnet_id                 = azurerm_subnet.ha_subnet.id
  network_security_group_id = azurerm_network_security_group.ha_nsg.id
}

resource "azurerm_network_security_group" "dr_nsg" {
  name                = "dr-nsg"
  location            = azurerm_resource_group.dr_rg.location
  resource_group_name = azurerm_resource_group.dr_rg.name

  security_rule {
    name                       = "AllowSSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "AllowHTTP"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowHTTPS"
    priority                   = 1003
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowGrafana"
    priority                   = 1004
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3000"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowPrometheus"
    priority                   = 1005
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "9090"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowAlertmanager"
    priority                   = 1006
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "9093"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "dr_subnet_nsg" {
  subnet_id                 = azurerm_subnet.dr_subnet.id
  network_security_group_id = azurerm_network_security_group.dr_nsg.id
}

############################
# Network Interfaces
############################

resource "azurerm_network_interface" "ha_nic" {
  count               = 3
  name                = "vm-ha-nic-${count.index}"
  location            = azurerm_resource_group.ha_rg.location
  resource_group_name = azurerm_resource_group.ha_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.ha_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.0.${count.index + 4}"
  }
}

resource "azurerm_network_interface" "dr_nic" {
  count               = 3
  name                = "vm-dr-nic-${count.index}"
  location            = azurerm_resource_group.dr_rg.location
  resource_group_name = azurerm_resource_group.dr_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.dr_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.1.0.${count.index + 4}"
  }
}

resource "azurerm_network_interface" "haproxy_ha_nic" {
  name                = "vm-haproxy-ha-nic"
  location            = azurerm_resource_group.ha_rg.location
  resource_group_name = azurerm_resource_group.ha_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.ha_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.0.100"
    public_ip_address_id          = azurerm_public_ip.pip.id
  }
}

resource "azurerm_network_interface" "haproxy_dr_nic" {
  name                = "vm-haproxy-dr-nic"
  location            = azurerm_resource_group.dr_rg.location
  resource_group_name = azurerm_resource_group.dr_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.dr_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.1.0.100"
    public_ip_address_id          = azurerm_public_ip.pip2.id
  }
}

resource "azurerm_network_interface" "monitoring_ha_nic" {
  name                = "vm-monitoring-ha-nic"
  location            = azurerm_resource_group.ha_rg.location
  resource_group_name = azurerm_resource_group.ha_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.ha_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.0.20"
    public_ip_address_id          = azurerm_public_ip.pip3.id
  }
}

resource "azurerm_network_interface" "monitoring_dr_nic" {
  name                = "vm-monitoring-dr-nic"
  location            = azurerm_resource_group.dr_rg.location
  resource_group_name = azurerm_resource_group.dr_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.dr_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.1.0.20"
    public_ip_address_id          = azurerm_public_ip.pip4.id
  }
}

resource "azurerm_network_interface" "backup_ha_nic" {
  name                = "vm-backup-ha-nic"
  location            = azurerm_resource_group.ha_rg.location
  resource_group_name = azurerm_resource_group.ha_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.ha_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.0.30"
  }
}

resource "azurerm_network_interface" "backup_dr_nic" {
  name                = "vm-backup-dr-nic"
  location            = azurerm_resource_group.dr_rg.location
  resource_group_name = azurerm_resource_group.dr_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.dr_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.1.0.30"
  }
}