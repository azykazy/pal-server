terraform {
  required_version = ">= 1.9"

  # state はローカルではなく Azure Storage で管理する (機密値を含むため + PC 故障対策)。
  # このストレージアカウントは terraform destroy に巻き込まれないよう
  # あえて Terraform 管理外 (rg-tfstate, az CLI で作成) に置いている。
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "sttfstatepal878dff"
    container_name       = "tfstate"
    key                  = "pal-server.tfstate"
    use_azuread_auth     = true
  }

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.21"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}

  # 誤ったアカウント/サブスクリプションへの apply を防ぐため明示指定
  subscription_id = var.subscription_id

  # 既定の一括登録は新規サブスクリプションで 409 Conflict になりやすいため無効化。
  # 必要なプロバイダー (Compute/Network/Storage/Web) は az provider register で登録済み。
  resource_provider_registrations = "none"
}
