data "azurerm_client_config" "current" {}

# シークレット (サーバーパスワード等) は Key Vault にのみ置く。
# 値の投入は apply 後に az CLI で行い、Terraform (tfvars / state) には値を通さない。
resource "azurerm_key_vault" "main" {
  name                = "kv-${var.prefix}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  rbac_authorization_enabled = true
  purge_protection_enabled   = false
  soft_delete_retention_days = 7
}

locals {
  # バージョン指定なしの参照 (ローテーション時は最新が自動反映される)
  kv_secret_uri = {
    server_password     = "${azurerm_key_vault.main.vault_uri}secrets/server-password/"
    admin_password      = "${azurerm_key_vault.main.vault_uri}secrets/admin-password/"
    discord_webhook_url = "${azurerm_key_vault.main.vault_uri}secrets/discord-webhook-url/"
  }
}

# デプロイ実行者 (az login したユーザー) がシークレットを登録できるようにする
resource "azurerm_role_assignment" "deployer_kv_officer" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}
