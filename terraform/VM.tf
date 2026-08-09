############################
# Linux Virtual Machines
############################

# HA
resource "azurerm_linux_virtual_machine" "ha_vm" {
  count               = 3
  name                = "ubuntu-ha-vm-${count.index + 1}"
  resource_group_name = azurerm_resource_group.ha_rg.name
  location            = azurerm_resource_group.ha_rg.location
  size                = "Standard_B2as_v2"

  admin_username = "patroni"
  admin_password = "P@ssw0rd2026"

  network_interface_ids = [
    azurerm_network_interface.ha_nic[count.index].id
  ]

  disable_password_authentication = false

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  computer_name = "ha${count.index + 1}"
}

# DR
resource "azurerm_linux_virtual_machine" "dr_vm" {
  count               = 3
  name                = "ubuntu-dr-vm-${count.index + 1}"
  resource_group_name = azurerm_resource_group.dr_rg.name
  location            = azurerm_resource_group.dr_rg.location
  size                = "Standard_B2as_v2"

  admin_username = "patroni"
  admin_password = "P@ssw0rd2026"

  network_interface_ids = [
    azurerm_network_interface.dr_nic[count.index].id
  ]

  disable_password_authentication = false

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  computer_name = "dr${count.index + 1}"
}

# HAproxy
resource "azurerm_linux_virtual_machine" "haproxy_ha_vm" {
  name                = "ubuntu-haproxy-ha-vm"
  resource_group_name = azurerm_resource_group.ha_rg.name
  location            = azurerm_resource_group.ha_rg.location
  size                = "Standard_B2as_v2"

  admin_username = "patroni"
  admin_password = "P@ssw0rd2026"

  network_interface_ids = [azurerm_network_interface.haproxy_ha_nic.id]

  disable_password_authentication = false

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  computer_name = "haproxy-ha"
}

resource "azurerm_linux_virtual_machine" "haproxy_dr_vm" {
  name                = "ubuntu-haproxy-dr-vm"
  resource_group_name = azurerm_resource_group.dr_rg.name
  location            = azurerm_resource_group.dr_rg.location
  size                = "Standard_B2as_v2"

  admin_username = "patroni"
  admin_password = "P@ssw0rd2026"

  network_interface_ids = [azurerm_network_interface.haproxy_dr_nic.id]

  disable_password_authentication = false

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  computer_name = "haproxy-dr"
}

# Monitoring
resource "azurerm_linux_virtual_machine" "monitoring_vm" {
  name                = "ubuntu-monitoring-vm"
  resource_group_name = azurerm_resource_group.ha_rg.name
  location            = azurerm_resource_group.ha_rg.location
  size                = "Standard_B2as_v2"

  admin_username = "patroni"
  admin_password = "P@ssw0rd2026"

  network_interface_ids = [azurerm_network_interface.monitoring_nic.id]

  disable_password_authentication = false

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  computer_name = "monitoring"
}

# Backup
resource "azurerm_linux_virtual_machine" "backup_vm" {
  name                = "ubuntu-backup-vm"
  resource_group_name = azurerm_resource_group.ha_rg.name
  location            = azurerm_resource_group.ha_rg.location
  size                = "Standard_B2as_v2"

  admin_username = "patroni"
  admin_password = "P@ssw0rd2026"

  network_interface_ids = [azurerm_network_interface.backup_nic.id]

  disable_password_authentication = false

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  computer_name = "backup"
}