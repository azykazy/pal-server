locals {
  docker_compose = templatefile("${path.module}/../vm/docker-compose.yml.tftpl", {
    server_name = var.server_name
    max_players = var.max_players
    game_port   = local.game_port
  })

  palworld_stop = file("${path.module}/../vm/palworld-stop.sh")

  fetch_secrets = templatefile("${path.module}/../vm/fetch-secrets.sh.tftpl", {
    key_vault_uri          = azurerm_key_vault.main.vault_uri
    game_settings_blob_url = "${azurerm_storage_account.func.primary_blob_endpoint}${azurerm_storage_container.game_config.name}/settings.env"
    storage_account_name   = azurerm_storage_account.func.name
  })

  auto_stop = templatefile("${path.module}/../vm/auto-stop.sh.tftpl", {
    idle_checks       = var.idle_checks
    internal_stop_url = "https://${azurerm_function_app_flex_consumption.bot.default_hostname}/api/internal-stop?code=${data.azurerm_function_app_host_keys.bot.default_function_key}"
  })

  cloud_init = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    docker_compose = local.docker_compose
    palworld_stop  = local.palworld_stop
    fetch_secrets  = local.fetch_secrets
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

  # Key Vault からのシークレット取得 (fetch-secrets.sh) に使用
  identity {
    type = "SystemAssigned"
  }

  custom_data = base64encode(local.cloud_init)

  # cloud-init は初回起動時のみ適用されるため、変更しても VM を再作成する必要はない。
  # fetch-secrets.sh 等の更新は az vm run-command で直接 VM 上のファイルを書き換える。
  lifecycle {
    ignore_changes = [custom_data]
  }
}
