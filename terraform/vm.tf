locals {
  docker_compose = templatefile("${path.module}/../vm/docker-compose.yml.tftpl", {
    server_name     = var.server_name
    server_password = var.server_password
    admin_password  = var.palworld_admin_password
    max_players     = var.max_players
    game_port       = local.game_port
  })

  palworld_stop = templatefile("${path.module}/../vm/palworld-stop.sh.tftpl", {
    admin_password = var.palworld_admin_password
  })

  auto_stop = templatefile("${path.module}/../vm/auto-stop.sh.tftpl", {
    admin_password      = var.palworld_admin_password
    idle_checks         = var.idle_checks
    discord_webhook_url = var.discord_webhook_url
    internal_stop_url   = "https://${azurerm_function_app_flex_consumption.bot.default_hostname}/api/internal-stop?code=${data.azurerm_function_app_host_keys.bot.default_function_key}"
  })

  cloud_init = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    docker_compose = local.docker_compose
    palworld_stop  = local.palworld_stop
    auto_stop      = local.auto_stop
  })
}

resource "azurerm_linux_virtual_machine" "palworld" {
  name                = local.vm_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  size                = var.vm_size

  # Spot: 使っている間だけ課金。eviction されてもディスクを保持して再起動できるようにする
  priority        = "Spot"
  eviction_policy = "Deallocate"
  max_bid_price   = -1 # 価格理由では evict しない (容量理由の eviction は起こり得る)

  admin_username                  = var.admin_username
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  network_interface_ids = [azurerm_network_interface.vm.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 32
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  custom_data = base64encode(local.cloud_init)
}
