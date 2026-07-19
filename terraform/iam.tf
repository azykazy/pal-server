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

# /palworld cost 用: サブスクリプション全体のコスト読み取り (読み取り専用)
data "azurerm_subscription" "current" {}

resource "azurerm_role_assignment" "func_cost_reader" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Cost Management Reader"
  principal_id         = azurerm_function_app_flex_consumption.bot.identity[0].principal_id
}

# Key Vault のシークレット読み取り (app settings の Key Vault 参照の解決に必要)
resource "azurerm_role_assignment" "func_kv_secrets_user" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_function_app_flex_consumption.bot.identity[0].principal_id
}

# VM が起動時に fetch-secrets.sh でパスワードを生成・更新するために Secrets Officer が必要
resource "azurerm_role_assignment" "vm_kv_secrets_officer" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azurerm_linux_virtual_machine.palworld.identity[0].principal_id
}
