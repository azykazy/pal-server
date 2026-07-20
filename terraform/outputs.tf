output "interactions_endpoint_url" {
  description = "Discord Developer Portal の INTERACTIONS ENDPOINT URL に登録する URL"
  value       = "https://${azurerm_function_app_flex_consumption.bot.default_hostname}/api/interactions"
}

output "function_app_name" {
  description = "Function App 名"
  value       = azurerm_function_app_flex_consumption.bot.name
}

output "resource_group_name" {
  description = "リソースグループ名"
  value       = azurerm_resource_group.main.name
}

output "vm_name" {
  description = "Palworld サーバー VM 名"
  value       = azurerm_linux_virtual_machine.palworld.name
}

output "key_vault_name" {
  description = "シークレット格納先の Key Vault 名 (scripts/seed-secrets.sh が使用)"
  value       = azurerm_key_vault.main.name
}

output "storage_account_name" {
  description = "ゲーム設定ファイルを保存するストレージアカウント名 (scripts/seed-secrets.sh が使用)"
  value       = azurerm_storage_account.func.name
}

# 接続用の IP は起動のたびに変わるため出力しない。
# /palworld start・/palworld status が Discord 上に都度表示する。
