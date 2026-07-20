resource "azurerm_storage_account" "func" {
  name                     = "st${var.prefix}${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
}

resource "azurerm_storage_container" "deploy" {
  name                  = "function-releases"
  storage_account_id    = azurerm_storage_account.func.id
  container_access_type = "private"
}

# Discord からの deferred 処理を渡すジョブキュー
resource "azurerm_storage_queue" "jobs" {
  name                 = "palworld-jobs"
  storage_account_name = azurerm_storage_account.func.name
}

# ローカルのセーブデータ移行用 (Portal から zip をアップロードし、VM が取り込む)
resource "azurerm_storage_container" "save_import" {
  name                  = "save-import"
  storage_account_id    = azurerm_storage_account.func.id
  container_access_type = "private"
}

# ゲームバランス設定ファイル置き場 (vm/game-settings.env を seed-secrets でアップロード)
resource "azurerm_storage_container" "game_config" {
  name                  = "game-config"
  storage_account_id    = azurerm_storage_account.func.id
  container_access_type = "private"
}

resource "azurerm_service_plan" "func" {
  name                = "plan-${var.prefix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  os_type             = "Linux"
  sku_name            = "FC1"
}

resource "azurerm_function_app_flex_consumption" "bot" {
  name                = "func-${var.prefix}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  service_plan_id     = azurerm_service_plan.func.id

  storage_container_type      = "blobContainer"
  storage_container_endpoint  = "${azurerm_storage_account.func.primary_blob_endpoint}${azurerm_storage_container.deploy.name}"
  storage_authentication_type = "StorageAccountConnectionString"
  storage_access_key          = azurerm_storage_account.func.primary_access_key

  runtime_name           = "node"
  runtime_version        = "20"
  maximum_instance_count = 40
  instance_memory_in_mb  = 2048
  https_only             = true

  site_config {}

  identity {
    type = "SystemAssigned"
  }

  app_settings = {
    # 注意: SCM_DO_BUILD_DURING_DEPLOYMENT は Flex SKU 非サポート。
    # 依存は zip に node_modules を同梱する (scripts/build-functions.sh)

    DISCORD_PUBLIC_KEY     = var.discord_public_key
    DISCORD_APPLICATION_ID = var.discord_application_id
    # シークレットは Key Vault 参照で解決 (Managed Identity + Key Vault Secrets User)
    DISCORD_WEBHOOK_URL = "@Microsoft.KeyVault(SecretUri=${local.kv_secret_uri.discord_webhook_url})"

    AZURE_SUBSCRIPTION_ID = var.subscription_id
    RESOURCE_GROUP        = azurerm_resource_group.main.name
    VM_NAME               = local.vm_name
    NIC_NAME              = local.nic_name
    PIP_NAME              = local.pip_name
    LOCATION              = var.location

    GAME_PORT       = tostring(local.game_port)
    KEY_VAULT_URI   = azurerm_key_vault.main.vault_uri
    SERVER_PASSWORD = "@Microsoft.KeyVault(SecretUri=${local.kv_secret_uri.server_password})"
  }

  # コードのデプロイは Terraform では行わない (Flex への zip 発行が不安定なため)。
  # scripts/deploy-functions.sh (az functionapp deployment source config-zip) を使う。
}

data "azurerm_function_app_host_keys" "bot" {
  name                = azurerm_function_app_flex_consumption.bot.name
  resource_group_name = azurerm_resource_group.main.name

  depends_on = [azurerm_function_app_flex_consumption.bot]
}
