locals {
  # Function App の app_settings から VM を参照する際に循環参照を避けるため、
  # リソース名はすべて locals で先に確定させる
  vm_name   = "vm-${var.prefix}"
  nic_name  = "nic-${var.prefix}"
  pip_name  = "pip-${var.prefix}"
  game_port = 8211
}

resource "azurerm_resource_group" "main" {
  name     = "rg-${var.prefix}"
  location = var.location
}

resource "random_string" "suffix" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}
