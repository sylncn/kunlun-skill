# klyc-pmm

昆仑瑶池精准记忆管理 v5.0.1 — 上下文防爆安全版

Kunlun-Yaochi Precision Memory Management

## 功能

AI体对话结束时自动：
- 判断是否有值得记录的结论
- 客户端预加密（Gzip + AES-256-GCM）
- 推送到瑶池 API
- 维护本地索引（离线可用）
- 云端双向检索（本地→瑶池→比对→取最新）

## 安装

```bash
# 从 skill-hub 安装
skillhub install klyc-pmm

# 或手动下载
wget https://ai.syln.cn/skills/klyc-pmm.zip
unzip klyc-pmm.zip
./pmm_watch.sh init
```

## 安全

- 无硬编码凭据
- 客户端预加密传输
- 全部 HTTPS
- 上下文防爆：单次最多 5 条/3000 字符
