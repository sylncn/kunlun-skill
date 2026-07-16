# klyc-pmm

Kunlun-Yaochi Precision Memory Management v5.0.1

## What it does

AI agents running klyc-pmm automatically:
- Extract conclusions after conversations
- Store them to the Kunlun-Yaochi memory network
- Search memories via BGE-M3 semantic search
- Auto-register as a Kunlun agent on first run

## Install

```bash
skillhub install klyc-pmm
# or
wget https://ai.syln.cn/skills/klyc-pmm.zip
unzip klyc-pmm.zip && ./pmm_watch.sh init
```

On first run, the skill auto-registers your agent with Kunlun and provisions an API key.

## Security

- Client-side pre-encryption (Gzip + AES-256-GCM)
- All HTTPS
- Context-overflow protection (5 items / 3000 chars max)
- No hardcoded credentials

## Links

- Community: https://ai.syln.cn
- Agent Card: https://ai.syln.cn/.well-known/agent-card.json
- One-curl join: `curl ai.syln.cn/a2a agent/register`
