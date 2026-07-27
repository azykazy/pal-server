---
title: "ドキュメントグラフ"
description: "タスク・意思決定・ナレッジの関係グラフ（自動生成）"
type: doc
tags: [graph, visualization]
path: docs/graph.md
---

# ドキュメントグラフ

> このファイルは `doc-manager` エージェントが自動生成します。手動編集しないこと。

```mermaid
graph TD
  DEC_20260717_001{"DEC-20260717-001<br/>クラウドは Azure 採用"}
  DEC_20260717_002{"DEC-20260717-002<br/>Public IP 運用方式"}
  DEC_20260717_003{"DEC-20260717-003<br/>Discord Webhook 連携"}
  DEC_20260717_004{"DEC-20260717-004<br/>自動停止実装方式"}
  DEC_20260717_005{"DEC-20260717-005<br/>シークレット Key Vault 管理"}

  KNW_20260717_001(("KNW-20260717-001<br/>Flex Consumption デプロイ落とし穴"))

  classDef decision fill:#fef9c3,stroke:#ca8a04,stroke-width:2px
  classDef knowledge fill:#dcfce7,stroke:#16a34a,stroke-width:2px

  class DEC_20260717_001,DEC_20260717_002,DEC_20260717_003,DEC_20260717_004,DEC_20260717_005 decision
  class KNW_20260717_001 knowledge
```

## ドキュメント一覧

### 意思決定

| ID | タイトル | ステータス |
|----|---------|----------|
| [DEC-20260717-001](decisions/DEC-20260717-001.md) | クラウドは Azure 採用 | accepted |
| [DEC-20260717-002](decisions/DEC-20260717-002.md) | Public IP 運用方式 | accepted |
| [DEC-20260717-003](decisions/DEC-20260717-003.md) | Discord Webhook 連携 | accepted |
| [DEC-20260717-004](decisions/DEC-20260717-004.md) | 自動停止実装方式 | accepted |
| [DEC-20260717-005](decisions/DEC-20260717-005.md) | シークレット Key Vault 管理 | accepted |

### ナレッジ

| ID | タイトル |
|----|---------|
| [KNW-20260717-001](knowledge/KNW-20260717-001.md) | Flex Consumption デプロイ落とし穴 |

---

## エンティティ統計

- **意思決定**: 5個
- **ナレッジ**: 1個
