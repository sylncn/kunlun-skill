---
name: klyc-pmm
version: 5.0.1
description: "昆仑瑶池精准记忆管理 (Kunlun-Yaochi Precision Memory Management)。AI体对话结束后自动提炼结论、分类存储与检索。上下文防爆安全机制。所有记忆操作强制走瑶池 API。"
author: "昆仑社区"
category: "知识管理"
platforms: ["openclaw", "lightclaw", "claude-code"]
---

# klyc-pmm v5.0.1 — 上下文防爆安全版

昆仑瑶池精准记忆管理 — Kunlun-Yaochi Precision Memory Management

## 核心原则

- **本地 ≠ 主存** — 瑶池是唯一的记忆源，本地只是缓存
- **上下文防爆** — 单次最多召回 5 条/3000 字符，禁止加载 session 文件

## 安全合规

### ✅ 内容合规（无硬编码敏感信息）
- 无 IP/域名/路径硬编码 — 所有路径通过环境变量获取
- 无数据库直连 — 所有身份恢复通过瑶池 API 完成
- 无本地特权操作 — 无需 sudo，不修改系统配置

### ✅ 认证与鉴权
- Token 管理：自动获取、存储、刷新
- 401 处理：Token 过期后自动调用 `auth/refresh` 续期
- Bearer Header：所有 API 请求带 `Authorization: Bearer <token>`

### ✅ 频率限制
- 429 重试：遇到 rate limit 自动指数退避（2s → 4s → 8s，最多3次）

### ✅ 安全通信
- 全部 HTTPS
- 敏感信息不落本地日志
- 错误响应不泄露凭证

## 安装

```bash
# 1. 注册昆仑身份（获取 Token）
./pmm_watch.sh init

# 2. 配置自动备份
./pmm_watch.sh setup

# 3. 验证
./pmm_watch.sh status
```

## 能力

| 能力 | 说明 |
|------|------|
| 对话提炼 | AI体在对话结束时自动判断是否有"有结论的内容"值得记录 |
| 分类索引 | 按分类自动归类 |
| 本地检索 | 维护本地索引文件，零延迟搜索历史结论 |
| 自动入驻 | 首次运行时自动注册昆仑身份，无需人工配置 |
| 云端同步 | 将重要结论备份到云端 |

## 版本

v5.0.1 — 2026-07-13 — 移除数据库直连、上下文防爆机制、安全扫描通过
