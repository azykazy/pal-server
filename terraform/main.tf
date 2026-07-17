locals {
  # Function App の app_settings から VM を参照する際に循環参照を避けるため、
  # リソース名はすべて locals で先に確定させる
  vm_name   = "vm-${var.prefix}"
  nic_name  = "nic-${var.prefix}"
  pip_name  = "pip-${var.prefix}"
  game_port = 8211
}

# リソースグループはポータルで作成済みのものを import して管理する
import {
  to = azurerm_resource_group.main
  id = "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name}"
}

resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
}

resource "random_string" "suffix" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}
