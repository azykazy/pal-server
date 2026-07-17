# Function の Managed Identity に必要最小限の権限を与える。
# - VM スコープ: 起動 / 割り当て解除 / Run Command (graceful stop)
# - リソースグループ スコープ: Public IP の作成・削除、NIC への付け外し
resource "azurerm_role_assignment" "func_vm_contributor" {
  scope                = azurerm_linux_virtual_machine.palworld.id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = azurerm_function_app_flex_consumption.bot.identity[0].principal_id
}

resource "azurerm_role_assignment" "func_network_contributor" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_function_app_flex_consumption.bot.identity[0].principal_id
}
