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
    # zip デプロイ時にリモートビルド (npm install) を実行する
    SCM_DO_BUILD_DURING_DEPLOYMENT = "true"
    # zip の内容が変わったら再デプロイを発火させるためのハッシュ
    DEPLOY_HASH = fileexists(var.functions_zip_path) ? filemd5(var.functions_zip_path) : "missing"

    DISCORD_PUBLIC_KEY     = var.discord_public_key
    DISCORD_APPLICATION_ID = var.discord_application_id
    DISCORD_WEBHOOK_URL    = var.discord_webhook_url

    AZURE_SUBSCRIPTION_ID = var.subscription_id
    RESOURCE_GROUP        = azurerm_resource_group.main.name
    VM_NAME               = local.vm_name
    NIC_NAME              = local.nic_name
    PIP_NAME              = local.pip_name
    LOCATION              = var.location

    GAME_PORT       = tostring(local.game_port)
    SERVER_PASSWORD = var.server_password
  }

  zip_deploy_file = var.functions_zip_path
}

data "azurerm_function_app_host_keys" "bot" {
  name                = azurerm_function_app_flex_consumption.bot.name
  resource_group_name = azurerm_resource_group.main.name

  depends_on = [azurerm_function_app_flex_consumption.bot]
}
