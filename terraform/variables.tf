variable "subscription_id" {
  description = "パルワールド専用 Azure サブスクリプションの ID"
  type        = string
}

variable "location" {
  description = "デプロイ先リージョン"
  type        = string
  default     = "japaneast"
}

variable "resource_group_name" {
  description = "使用するリソースグループ名 (ポータルで作成済みのものを import する)"
  type        = string
  default     = "pal-server"
}

variable "prefix" {
  description = "リソース名のプレフィックス"
  type        = string
  default     = "palworld"
}

variable "vm_size" {
  description = "Spot VM のサイズ (B シリーズは Spot 非対応)"
  type        = string
  default     = "Standard_D4as_v5"
}

variable "admin_username" {
  description = "VM の管理者ユーザー名"
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key" {
  description = "VM への SSH 接続に使う公開鍵 (例: file(\"~/.ssh/id_ed25519.pub\") の中身)"
  type        = string
}

variable "allowed_ssh_cidr" {
  description = "SSH (22/tcp) を許可する CIDR。空文字なら SSH を一切開放しない"
  type        = string
  default     = ""
}

variable "server_name" {
  description = "Palworld サーバーの表示名"
  type        = string
  default     = "Palworld Private Server"
}

# パスワード類は Terraform 変数にせず Key Vault に直接格納する
# (apply 後に az keyvault secret set で投入。docs/SETUP.md 参照)

variable "max_players" {
  description = "最大同時接続人数"
  type        = number
  default     = 8
}

variable "idle_checks" {
  description = "自動停止までの 0 人チェック回数 (5 分間隔 × 回数。6 = 30 分)"
  type        = number
  default     = 6
}

variable "discord_public_key" {
  description = "Discord アプリケーションの Public Key (署名検証用)"
  type        = string
}

variable "discord_application_id" {
  description = "Discord アプリケーションの Application ID"
  type        = string
}

# Functions のコードデプロイは Terraform では行わない (scripts/deploy-functions.sh を使用)
