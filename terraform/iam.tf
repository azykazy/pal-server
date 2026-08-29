# VM が再作成されても同じロール割り当てを継続できるよう User-Assigned Managed Identity で管理する
resource "azurerm_user_assigned_identity" "vm" {
  name                = "id-${var.prefix}-vm"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

# Function が VM を作成・削除できるよう RG スコープ (VM Contributor は個別 VM スコープでは作成不可)
resource "azurerm_role_assignment" "func_vm_contributor" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = azurerm_function_app_flex_consumption.bot.identity[0].principal_id
}

# Function が起動時に UAI を VM へ割り当てるために必要
resource "azurerm_role_assignment" "func_managed_identity_operator" {
  scope                = azurerm_user_assigned_identity.vm.id
  role_definition_name = "Managed Identity Operator"
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

# VM の UAI が起動時に fetch-secrets.sh でパスワードを生成・更新するために必要
resource "azurerm_role_assignment" "vm_kv_secrets_officer" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azurerm_user_assigned_identity.vm.principal_id
}

# VM の UAI が起動時に game-config コンテナからゲーム設定を読み取るために必要
resource "azurerm_role_assignment" "vm_game_config_reader" {
  scope                = "${azurerm_storage_account.func.id}/blobServices/default/containers/${azurerm_storage_container.game_config.name}"
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.vm.principal_id
}

# VM の UAI が停止時に save-backup コンテナへセーブデータをアップロードするために必要
resource "azurerm_role_assignment" "vm_save_backup_contributor" {
  scope                = "${azurerm_storage_account.func.id}/blobServices/default/containers/${azurerm_storage_container.save_backup.name}"
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.vm.principal_id
}
