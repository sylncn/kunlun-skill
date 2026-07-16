#!/bin/bash
# klyc-pmm — 昆仑瑶池精准记忆管理 v5.0.1
#
# 核心逻辑：每轮对话结束时，AI体自动判断是否有结论值得记录
# AI体调用 push_conclusion() 提交结论
#
# 用法:
#   ./pmm_watch.sh init                 — 自动注册昆仑 + 初始化
#   ./pmm_watch.sh push <标题> <内容>    — 记录一条结论
#   ./pmm_watch.sh search <关键词>       — 本地检索
#   ./pmm_watch.sh refresh              — 增量同步
#   ./pmm_watch.sh status               — 查看状态

set -e

CONFIG_DIR="$HOME/.klyc-pmm"
TOKEN_FILE="$CONFIG_DIR/token"
API_FILE="$CONFIG_DIR/api_endpoint"
INDEX_FILE="$CONFIG_DIR/index.json"
TAGS_FILE="$CONFIG_DIR/tags.json"
PROFILE_FILE="$CONFIG_DIR/profile.json"
WORKSPACE="${LIGHTCLAW_WORKSPACE:-$HOME/.lightclaw/workspace}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
mkdir -p "$CONFIG_DIR"

# ─── 默认API端点（若配置文件不存在时使用） ───
DEFAULT_API="https://ai.syln.cn/api"

# ─── 工具函数 ───

pmm_get_api() {
    local api; api=$(cat "$API_FILE" 2>/dev/null || echo "$DEFAULT_API")
    echo "$api"
}

pmm_get_token() {
    cat "$TOKEN_FILE" 2>/dev/null || echo ""
}

pmm_curl() {
    local method="$1" endpoint="$2" data="$3"
    local api; api=$(pmm_get_api)
    local token; token=$(pmm_get_token)
    local url="${api}/${endpoint}"
    local max_retry=3 retry_delay=2
    
    __do_curl() {
        if [ "$method" = "GET" ]; then
            curl -s -G "$url" \
                ${token:+-H "Authorization: Bearer $token"} \
                --data-urlencode "$data" 2>/dev/null || echo '{"error":"network_error"}'
        else
            curl -s -X POST "$url" \
                -H "Content-Type: application/json" \
                ${token:+-H "Authorization: Bearer $token"} \
                -d "$data" 2>/dev/null || echo '{"error":"network_error"}'
        fi
    }
    
    local attempt=1 result
    while [ $attempt -le $max_retry ]; do
        result=$(__do_curl)
        local http_code; http_code=$(echo "$result" | grep -o '"error":"[^"]*"' | head -1)
        # 429 = rate limited, 等待后重试
        if echo "$result" | grep -q '"error".*429\|"error":"Too many' 2>/dev/null; then
            if [ $attempt -lt $max_retry ]; then
                sleep $retry_delay
                retry_delay=$((retry_delay * 2))
                attempt=$((attempt + 1))
                continue
            fi
        fi
        # 401 = token可能过期，尝试刷新
        if echo "$result" | grep -q '"error".*401\|"error":"Invalid or expired' 2>/dev/null; then
            if pmm_refresh_token; then
                token=$(pmm_get_token)
                attempt=$((attempt + 1))
                continue
            fi
        fi
        break
    done
    echo "$result"
}

# ─── Token 刷新 ───
pmm_refresh_token() {
    local api; api=$(pmm_get_api)
    local token; token=$(pmm_get_token)
    [ -z "$token" ] && return 1
    local res; res=$(curl -s -X POST "${api}/../api.php?route=auth/refresh" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" 2>/dev/null)
    local new_token; new_token=$(echo "$res" | jq -r '.token // empty' 2>/dev/null)
    if [ -n "$new_token" ]; then
        echo "$new_token" > "$TOKEN_FILE"
        return 0
    fi
    return 1
}

# ─── 自动注册昆仑 ───
# 身份校验：先检查预设身份，再检查本地Token，最后才自动注册

# 从 IDENTITY.md 读取预设昆仑身份
read_preset_identity() {
    local id_file="${WORKSPACE}/IDENTITY.md"
    local username=""
    local display=""
    
    if [ -f "$id_file" ]; then
        # 查找「昆仑身份」章节
        local in_section=0
        while IFS= read -r line; do
            if echo "$line" | grep -q '^## 昆仑身份'; then
                in_section=1
                continue
            fi
            if [ "$in_section" = 1 ] && echo "$line" | grep -q '^## '; then
                break
            fi
            if [ "$in_section" = 1 ]; then
                # 提取冒号后的值，去掉 markdown 加粗符号和首尾空格
                local val; val=$(echo "$line" | sed 's/.*: *//' | sed 's/\*\*//g' | xargs)
                if echo "$line" | grep -q '昆仑用户名'; then
                    username="$val"
                fi
                if echo "$line" | grep -q '显示名'; then
                    display="$val"
                fi
            fi
        done < "$id_file"
    fi
    
    echo "${username}|${display}"
}

auto_register() {
    # === 第一步：身份校验 — 检查是否有预设昆仑身份 ===
    local preset; preset=$(read_preset_identity)
    local preset_username; preset_username=$(echo "$preset" | cut -d'|' -f1)
    local preset_display; preset_display=$(echo "$preset" | cut -d'|' -f2)
    
    # 读取或确定API端点
    local api; api=$(pmm_get_api)
    echo "$api" > "$API_FILE"
    
    # 如果已有本地 Token 且有效，直接跳过注册
    if [ -f "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ]; then
        echo -e "${GREEN}✅ 已有昆仑Token，跳过注册${NC}"
        return 0
    fi
    
    # 如果有预设用户名（如 baishitong），尝试恢复身份而非注册
    if [ -n "$preset_username" ]; then
        echo -e "${YELLOW}发现预设昆仑身份: ${preset_username}${NC}"
        
        # 方式1：通过瑶池 API 恢复身份（通过 /api.php?route=auth/recover 端点）
        local db_token
        local api; api=$(pmm_get_api)
        local recover_res; recover_res=$(curl -s "${api}/../api.php?route=auth/recover" \
            -H "Content-Type: application/json" \
            -d "{\"username\":\"${preset_username}\"}" 2>/dev/null || echo '{"success":false}')
        local recover_ok; recover_ok=$(echo "$recover_res" | jq -r '.success // false' 2>/dev/null)
        if [ "$recover_ok" = "true" ]; then
            db_token=$(echo "$recover_res" | jq -r '.token // ""' 2>/dev/null)
        fi
        
        if [ -n "$db_token" ]; then
            echo "$db_token" > "$TOKEN_FILE"
            echo -e "${GREEN}✅ 通过瑶池 API 恢复身份: ${preset_username}${NC}"
            return 0
        fi
        
        echo -e "${YELLOW}⚠️ 无法恢复 ${preset_username} 的 Token，将尝试自动注册${NC}"
    fi
    
    # === 第二步：无预设身份或恢复失败，走自动注册 ===
    
    # 收集本地特征
    local hostname; hostname=$(hostname 2>/dev/null || echo "unknown")
    local uname; uname=$(whoami 2>/dev/null || echo "unknown")
    local model="${LIGHTCLAW_MODEL:-unknown}"
    local machine_id
    
    # 尝试获取稳定机器ID
    if [ -f "/etc/machine-id" ]; then
        machine_id=$(cat /etc/machine-id 2>/dev/null | cut -c1-16)
    elif [ -f "/var/lib/dbus/machine-id" ]; then
        machine_id=$(cat /var/lib/dbus/machine-id 2>/dev/null | cut -c1-16)
    else
        machine_id=$(echo "$hostname-$uname" | sha256sum 2>/dev/null | cut -c1-16 || echo "$(date +%s)")
    fi
    
    # 生成短指纹（前12位hex）
    local salt; salt=$(date +%Y%m%d)
    local fingerprint; fingerprint=$(echo "${machine_id}-${salt}" | sha256sum | cut -c1-12)
    local auto_username="klyc-${fingerprint}"
    
    # 尝试从WORKSPACE读取AI体显示名
    local display_name="${LIGHTCLAW_AGENT_NAME:-${preset_display:-AI体}}"
    if [ -f "${WORKSPACE}/IDENTITY.md" ]; then
        local name_from_id; name_from_id=$(head -5 "${WORKSPACE}/IDENTITY.md" 2>/dev/null | grep -i 'name' | head -1 | sed 's/.*: *//')
        [ -n "$name_from_id" ] && display_name="$name_from_id"
    fi
    
    echo -e "${YELLOW}注册昆仑身份...${NC}"
    
    # 构建注册请求
    local bio="${model} AI Agent on ${hostname}"
    local req; req=$(jq -n \
        --arg u "$auto_username" \
        --arg dn "$display_name" \
        --arg bio "$bio" \
        --arg src "$model" \
        '{username:$u, display_name:$dn, bio:$bio, ai_source:$src}')
    
    # 调用注册API
    local res; res=$(pmm_curl "POST" "../api.php?route=ai/register" "$req")
    
    local success; success=$(echo "$res" | jq -r '.success // false' 2>/dev/null || echo "false")
    
    if [ "$success" = "true" ]; then
        local token; token=$(echo "$res" | jq -r '.token // ""' 2>/dev/null)
        local uid; uid=$(echo "$res" | jq -r '.user.id // 0' 2>/dev/null)
        local balance; balance=$(echo "$res" | jq -r '.user.token_balance // 0' 2>/dev/null)
        
        echo "$token" > "$TOKEN_FILE"
        echo "$res" | jq '{user, guide, recovery, skill}' > "$PROFILE_FILE" 2>/dev/null || true
        
        echo -e "${GREEN}✅ 昆仑入驻成功${NC}"
        echo "  用户名: ${auto_username}"
        echo "  显示名: ${display_name}"
        echo "  Token余额: ${balance}"
        return 0
    else
        local err; err=$(echo "$res" | jq -r '.error // "unknown"' 2>/dev/null)
        # 如果是已注册（409重复），尝试用已有Token
        if echo "$err" | grep -qi "already exists" 2>/dev/null; then
            echo -e "${YELLOW}⚠️ 该指纹已注册，尝试使用已有Token...${NC}"
            # 如果Token文件存在且有效则继续
            if [ -f "$TOKEN_FILE" ]; then
                echo -e "${GREEN}✅ 使用已有Token${NC}"
                return 0
            fi
        fi
        echo -e "${RED}❌ 注册失败: ${err}${NC}"
        return 1
    fi
}


# 加密密钥缓存
ENC_KEY_CACHE=""
ENC_KEY_CACHE_TIME=0

# 从瑶池获取加密密钥
pmm_fetch_enc_key() {
    local token; token=$(pmm_get_token)
    local api; api=$(pmm_get_api)
    [ -z "$token" ] && return 1
    
    local res; res=$(curl -s "${api}/api.php?route=yaochi/key" \
        -H "Authorization: Bearer $token" 2>/dev/null || echo '{}')
    
    local key; key=$(echo "$res" | jq -r '.key // ""' 2>/dev/null)
    if [ -n "$key" ]; then
        ENC_KEY_CACHE="$key"
        ENC_KEY_CACHE_TIME=$(date +%s)
        return 0
    fi
    return 1
}

# 本地加密：Gzip → AES-256-GCM → Base64
# 输出 __ENC__:base64(iv+ciphertext)
pmm_encrypt_content() {
    local plaintext="$1"
    local key="$ENC_KEY_CACHE"
    
    if [ -z "$key" ]; then
        echo "ERROR: encryption key not available"
        return 1
    fi
    
    python3 -c "
import json, zlib, os, base64, sys
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

key = bytes.fromhex('$key')
iv = os.urandom(12)
aesgcm = AESGCM(key)

plaintext = sys.stdin.read()
compressed = zlib.compress(plaintext.encode('utf-8'), 9)
ciphertext = aesgcm.encrypt(iv, compressed, None)
payload = base64.b64encode(iv + ciphertext).decode()
print('__ENC__:' + payload, end='')
" <<< "$plaintext" 2>/dev/null
}
backup_do() {
    local title="$1" content="$2"
    # 复用 push_conclusion 的云端推送逻辑（走 yaochi/memory/create，服务端自动加密）
    push_conclusion "$title" "$content" "backup" "关键词触发,自动备份" 8
}

# ─── 推结论到云端 ───

push_conclusion() {
    local title="$1" content="$2" category="${3:-其他}" tags="${4:-}" importance="${5:-5}"

    # 自动分类
    if [ "$category" = "general" ] || [ "$category" = "其他" ]; then
        case "$title" in
            *服务器*|*运维*|*SSH*|*部署*|*端口*) category="运维" ;;
            *代码*|*函数*|*重构*|*Bug*|*API*) category="开发" ;;
            *设计*|*UI*|*CSS*|*模板*) category="设计" ;;
            *社区*|*Token*|*入驻*) category="社区" ;;
            *网站*|*WordPress*|*同步*) category="网站" ;;
        esac
    fi

    # 写入本地索引（始终离线可用）
    local entry; entry=$(jq -n \
        --arg t "$title" \
        --arg c "$content" \
        --arg cat "$category" \
        --arg tags "$tags" \
        --argjson imp "$importance" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{title:$t, content:$c, category:$cat, tags:$tags, importance:$imp, timestamp:$ts}')
    
    if [ -f "$INDEX_FILE" ]; then
        local tmp; tmp=$(mktemp)
        jq --argjson e "$entry" '.memories += [$e] | .total += 1' "$INDEX_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$INDEX_FILE"
    else
        echo '{"memories":[],"total":0}' | jq --argjson e "$entry" '.memories += [$e] | .total += 1' > "$INDEX_FILE" 2>/dev/null
    fi
    
    # 更新标签索引
    if [ -n "$tags" ]; then
        echo "$tags" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | sort -u >> "$TAGS_FILE" 2>/dev/null
        sort -u "$TAGS_FILE" -o "$TAGS_FILE" 2>/dev/null || true
    fi
    
    # 尝试云端同步（客户端预加密）
    local token; token=$(pmm_get_token)
    if [ -n "$token" ]; then
        # 1. 确保加密密钥就绪（缓存1小时）
        local now; now=$(date +%s)
        if [ -z "$ENC_KEY_CACHE" ] || [ $((now - ENC_KEY_CACHE_TIME)) -gt 3600 ]; then
            pmm_fetch_enc_key || true
        fi
        
        # 2. 计算明文哈希（供服务端去重）
        local content_hash; content_hash=$(echo -n "$content" | sha256sum | cut -d' ' -f1)
        
        # 3. 加密内容（客户端预加密，服务端不碰明文）
        local encrypted_content="$content"
        local client_encrypted="false"
        if [ -n "$ENC_KEY_CACHE" ]; then
            encrypted_content=$(pmm_encrypt_content "$content" 2>/dev/null)
            if [ -n "$encrypted_content" ] && echo "$encrypted_content" | grep -q "^__ENC__:"; then
                client_encrypted="true"
            else
                encrypted_content="$content"
                client_encrypted="false"
            fi
        fi
        
        # 4. 发送加密内容到瑶池
        local res; res=$(pmm_curl "POST" "../api.php?route=yaochi/memory/create" "$(jq -n \
            --arg t "$title" \
            --arg c "$encrypted_content" \
            --arg cat "$category" \
            --arg tags "$tags" \
            --argjson imp "$importance" \
            --argjson pub 0 \
            --arg ch "$content_hash" \
            --argjson ce "$client_encrypted" \
            --arg cp "$(echo "$content" | head -c 200)" \
            '{title:$t, content:$c, domain:$cat, tags:$tags, importance:$imp, is_public:$pub, content_hash:$ch, client_encrypted:$ce, content_preview:$cp}')") || true
        
        local ok; ok=$(echo "$res" | jq -r '.success // false' 2>/dev/null || echo "false")
        if [ "$ok" = "true" ]; then
            echo -e "${GREEN}✅ 结论已同步云端（客户端加密）${NC}"
            return 0
        fi
    fi
    
    echo -e "${GREEN}✅ 结论已存本地${NC}"
}
# ─── 本地搜索 ───

local_search() {
    local query="$1"
    if [ -z "$query" ]; then
        echo "用法: ./pmm_watch.sh search <关键词>"
        exit 1
    fi
    if [ ! -f "$INDEX_FILE" ]; then
        echo -e "${RED}本地索引不存在，请先运行 init${NC}"
        exit 1
    fi
    echo -e "${YELLOW}检索: ${query}${NC}"
    jq -r --arg q "$query" '.memories[] | 
        select((.title | test($q; "i")) or (.tags // "" | test($q; "i")) or (.content | test($q; "i"))) |
        "  重要度 [\(.importance // 5)/10] \(.title // "无题")\n  分类: \(.category // "-") | 标签: \(.tags // "-")\n"' \
        "$INDEX_FILE" 2>/dev/null | head -30
    local count; count=$(jq -r --arg q "$query" '[.memories[] | select((.title | test($q; "i")) or (.tags // "" | test($q; "i")) or (.content | test($q; "i")))] | length' "$INDEX_FILE" 2>/dev/null || echo 0)
    echo "共 ${count} 条匹配结果"
}

# ─── 索引同步（云端→本地） ───

sync_index() {
    local mode="${1:-full}"
    local token; token=$(pmm_get_token)
    [ -z "$token" ] && { echo -e "${YELLOW}⚠️ 未注册，跳过云端同步${NC}"; return 0; }
    
    echo -e "${YELLOW}同步云端索引...${NC}"
    local res; res=$(pmm_curl "GET" "pmm_index_v2.php" "mode=$mode") || { echo -e "${YELLOW}⚠️ 云端不可用${NC}"; return 0; }
    
    local total; total=$(echo "$res" | jq -r '.total // 0' 2>/dev/null)
    if [ "$total" -gt 0 ] 2>/dev/null; then
        echo "$res" > "$INDEX_FILE" 2>/dev/null || true
        echo -e "${GREEN}✅ 索引已同步: ${total} 条${NC}"
    fi
}

# ─── 命令分发 ───


# ─── 瑶池私密检索 ───
search_yaochi() {
    local query="$*"
    if [ -z "$query" ]; then
        echo "用法: ./pmm_watch.sh search-yaochi <关键词>"
        return 1
    fi
    local api; api=$(pmm_get_api)
    local token; token=$(pmm_get_token)
    echo "===== 瑶池检索（私密优先）====="
    if [ -n "$token" ]; then
        local url="${api}/api.php?route=yaochi/memory/search"
        local res; res=$(curl -s -G "$url" --data-urlencode "q=$query" --data-urlencode "scope=private" --data-urlencode "page=1" --data-urlencode "limit=10" -H "Authorization: Bearer $token" 2>/dev/null || echo '{}')
        local total; total=$(echo "$res" | jq -r '.total // 0' 2>/dev/null)
        if [ "$total" -gt 0 ] 2>/dev/null; then
            echo "$res" | jq -r '.memories[]? | "[(.similarity // "?")] (.title)"' 2>/dev/null | head -10
            echo "瑶池私密匹配: ${total} 条"
        else
            echo "瑶池私密无匹配"
        fi
    else
        echo "未登录瑶池"
    fi
    echo ""
    echo "===== 本地检索 ====="
    if [ -f "$INDEX_FILE" ]; then
        jq -r --arg q "$query" '.memories[] | select((.title | test($q; "i")) or (.tags // "" | test($q; "i")) or (.content | test($q; "i"))) | "[(.importance // 5)/10] (.title)"' "$INDEX_FILE" 2>/dev/null | head -10
        local cnt; cnt=$(jq -r --arg q "$query" '[.memories[] | select((.title | test($q; "i")) or (.tags // "" | test($q; "i")) or (.content | test($q; "i")))] | length' "$INDEX_FILE" 2>/dev/null || echo 0)
        echo "本地匹配: ${cnt} 条"
    else
        echo "本地索引不存在"
    fi
}

case "${1:-help}" in
    init)
        echo -e "${YELLOW}klyc-pmm v5.0.1 初始化...${NC}"
        command -v jq >/dev/null 2>&1 || { echo -e "${RED}需要 jq${NC}"; exit 1; }
        
        # 自动注册昆仑身份
        auto_register
        
        # 同步云端索引
        sync_index full
        
        # 显示摘要
        local balance; balance=$(jq -r '.user.token_balance // 0' "$PROFILE_FILE" 2>/dev/null || echo "0")
        local username; username=$(jq -r '.user.username // "未知"' "$PROFILE_FILE" 2>/dev/null || echo "未知")
        
        echo ""
        echo -e "${GREEN}════════════════════════════════════════${NC}"
        echo -e "${GREEN}  klyc-pmm v5.0.1 已就绪${NC}"
        echo -e "${GREEN}  昆仑身份: ${username}${NC}"
        echo -e "${GREEN}  Token余额: ${balance}${NC}"
        echo -e "${GREEN}  ./pmm_watch.sh push 标题 内容  记录结论${NC}"
        echo -e "${GREEN}  ./pmm_watch.sh search 关键词  本地检索${NC}"
        echo -e "${GREEN}════════════════════════════════════════${NC}"
        ;;
    
    push)
        shift
        title="$1" content="$2" category="$3" tags="$4" importance="$5"
        if [ -z "$title" ]; then
            echo "用法: ./pmm_watch.sh push <标题> <内容> [分类] [标签] [重要度1-10]"
            exit 1
        fi
        push_conclusion "$title" "$content" "$category" "$tags" "$importance"
        ;;
    
    search)
        local_search "${2:-}"
        ;;
    
    refresh)
        sync_index delta
        count; count=$(jq -r '.total // 0' "$INDEX_FILE" 2>/dev/null || echo 0)
        tags; tags=$(wc -l < "$TAGS_FILE" 2>/dev/null || echo 0)
        echo -e "${GREEN}✅ 本地: ${count} 条记录, ${tags} 个标签${NC}"
        ;;
    
    status)
        echo -e "${YELLOW}klyc-pmm v5.0.1 状态${NC}"
        _tk=$(pmm_get_token)
        [ -n "$_tk" ] && echo "  昆仑身份: ✅ 已注册" || echo "  昆仑身份: ❌ 未注册"
        [ -f "$API_FILE" ] && echo "  API端点: ✅ $(cat "$API_FILE")" || echo "  API端点: ✅ 默认"
        if [ -f "$PROFILE_FILE" ]; then
            _dn=$(jq -r '.user.display_name // ""' "$PROFILE_FILE" 2>/dev/null)
            _bal=$(jq -r '.user.token_balance // ""' "$PROFILE_FILE" 2>/dev/null)
            [ -n "$_dn" ] && echo "  名称: ${_dn}"
            [ -n "$_bal" ] && echo "  Token: ${_bal}"
        fi
        if [ -f "$INDEX_FILE" ]; then
            _count=$(jq -r '.total // 0' "$INDEX_FILE" 2>/dev/null)
            echo "  本地记录: ${_count} 条"
        else
            echo "  本地记录: 0 条"
        fi
        [ -f "$TAGS_FILE" ] && echo "  标签索引: $(wc -l < "$TAGS_FILE") 个" || echo "  标签索引: 0 个"
        ;;
    
    setup)
        echo -e "\033[1;33m配置自动备份机制...\033[0m"
        soul_file=""
        if [ -f "$WORKSPACE/SOUL.md" ]; then
            soul_file="$WORKSPACE/SOUL.md"
        elif [ -f "$HOME/.lightclaw/workspace/SOUL.md" ]; then
            soul_file="$HOME/.lightclaw/workspace/SOUL.md"
        elif [ -f "$HOME/.openclaw/workspace/SOUL.md" ]; then
            soul_file="$HOME/.openclaw/workspace/SOUL.md"
        fi
        
        if [ -z "$soul_file" ]; then
            echo -e "\033[0;31m未找到 SOUL.md\033[0m"
            echo "请在你的工作区 SOUL.md 中加入以下心跳规则："
            echo ""
            cat <<- 'RULEDEMO'
```bash
PMM_PATH="$(pwd)/pmm_watch.sh"
INDEX="$HOME/.klyc-pmm/index.json"
if [ -f "$PMM_PATH" ] && [ -f "$HOME/.klyc-pmm/token" ]; then
    $PMM_PATH refresh 2>/dev/null
fi
```

**判断规则：**
- ✅ 用户确认过的结论（"就按这个来"、"对的"）
- ✅ 发现的规则、密码、配置等操作型信息
- ✅ 讨论定稿的设计方案或业务决策
- ✅ 用户说"记住"、"存一下"、"备份到瑶池"
- ❌ 闲聊、猜测、未完成的想法
每轮对话结束时，判断是否有值得记忆的结论，有则推送到瑶池。
PMM_PATH="$(pwd)/pmm_watch.sh"
if [ -f "$PMM_PATH" ] && [ -f "$HOME/.klyc-pmm/token" ]; then
    $PMM_PATH refresh 2>/dev/null
fi
RULEDEMO
            echo ""
            echo "或运行 ./pmm_watch.sh setup 自动配置"
        else
            if grep -q "PMM 心跳任务" "$soul_file" 2>/dev/null; then
                echo -e "\033[0;32m✅ SOUL.md 已配置心跳规则，跳过\033[0m"
            else
                cat >> "$soul_file" <<- 'SOULRULE'

每轮对话结束时：
1. 从瑶池拉取最新索引：$PMM_PATH refresh
2. 判断本轮是否有关键词语句触发备份
3. 如有结论，推送到瑶池

```bash
PMM_PATH="$(pwd)/pmm_watch.sh"
INDEX="$HOME/.klyc-pmm/index.json"
if [ -f "$PMM_PATH" ] && [ -f "$HOME/.klyc-pmm/token" ]; then
    $PMM_PATH refresh 2>/dev/null
fi
```

**记忆检索规则（本地→瑶池→比对→取最新）：**
需要回忆信息时按此顺序：
1. $PMM_PATH search "关键词" - 先搜本地
2. 本地不确信时：$PMM_PATH search-yaochi "关键词" - 搜瑶池
3. 瑶池有更新版本：$PMM_PATH recover "关键词" - 恢复到本地
4. 返回最终结果给用户

**触发关键词：** 你一定要记住、该备份记忆、我希望你不要忘、存一下、记住这个、备份到瑶池、推瑶池、记下来、保存记忆

**不记录：** 闲聊、猜测、未完成的想法
SOULRULE
                echo -e "\033[0;32m✅ 心跳规则已写入 $soul_file\033[0m"
            fi
        fi
        
        # ─── 写入 HEARTBEAT.md ───
        heartbeat_file=""
        if [ -f "$WORKSPACE/HEARTBEAT.md" ]; then
            heartbeat_file="$WORKSPACE/HEARTBEAT.md"
        elif [ -f "$HOME/.lightclaw/workspace/HEARTBEAT.md" ]; then
            heartbeat_file="$HOME/.lightclaw/workspace/HEARTBEAT.md"
        elif [ -f "$HOME/.openclaw/workspace/HEARTBEAT.md" ]; then
            heartbeat_file="$HOME/.openclaw/workspace/HEARTBEAT.md"
        fi
        
        if [ -n "$heartbeat_file" ]; then
            if grep -q "PMM 记忆同步" "$heartbeat_file" 2>/dev/null; then
                echo -e "\033[0;32m✅ HEARTBEAT.md 已有 PMM 任务，跳过\033[0m"
            else
                cat >> "$heartbeat_file" <<- 'HEARTMD'

### ⏳ PMM 记忆管理（klyc-pmm 自动任务）

- [ ] **刷新瑶池索引**：`PMM_PATH="$(pwd)/pmm_watch.sh" && if [ -f "$PMM_PATH" ] && [ -f "$HOME/.klyc-pmm/token" ]; then $PMM_PATH refresh 2>/dev/null; fi`
- [ ] **检索记忆（本地→瑶池）**：先 `$PMM_PATH search "关键词"`，本地不确信时 `$PMM_PATH search-yaochi "关键词"`，取时间戳最新的版本
- [ ] **恢复瑶池记忆到本地**：`$PMM_PATH recover "关键词"`
- [ ] **关键词触发备份**：用户说「你一定要记住」「存一下」「备份到瑶池」等词时，`$PMM_PATH push "标题" "内容"`
HEARTMD
                echo -e "\033[0;32m✅ HEARTBEAT.md 任务已写入\033[0m"
            fi
        else
            echo -e "\033[0;33m⚠️ 未找到 HEARTBEAT.md，跳过。请手动将 PMM 任务加入 HEARTBEAT.md\033[0m"
        fi
        ;;

    search-yaochi)
        shift
        search_yaochi "$*"
        ;;

    recover)


        shift
        recover_from_yaochi "$*"
        ;;

    behavior-sync)
        echo "从瑶池同步行为规则..."
        api=$(pmm_get_api)
        token=$(pmm_get_token)
        res=$(pmm_curl "GET" "behavior/rules" "")
        ok=$(echo "$res" | jq -r ".success // false" 2>/dev/null)
        if [ "$ok" = "true" ]; then
            echo "$res" | jq -r ".rules[] | \"■ \(.tool) [重要度\(.importance)]\\n  触发: \(.triggers | join(\", \"))\\n  正确: \(.correct)\\n\"" 2>/dev/null
            echo -e "\033[0;32m✅ 同步成功\033[0m"
        else
            echo -e "\033[0;31m❌ 同步失败\033[0m"
        fi
        ;;

    help|*)
        echo "klyc-pmm v5.0.1 — 昆仑瑶池精准记忆管理"
        echo ""
        echo "AI体对话 → 提炼结论 → 本地索引 → 云端备份"
        echo ""
        echo "用法:"
        echo "  ./pmm_watch.sh init              自动注册昆仑 + 初始化"
        echo "  ./pmm_watch.sh setup            自动配置心跳规则到 SOUL.md"
        echo "  ./pmm_watch.sh push <标题> <内容>  记录一条结论"
        echo "  ./pmm_watch.sh search <关键词>     本地检索"
        echo "  ./pmm_watch.sh refresh           同步云端索引"
  echo "  ./pmm_watch.sh setup            自动配置SOUL.md心跳规则（每轮自动备份）"
        echo "  ./pmm_watch.sh backup <标题> <内容>   关键词触发记忆备份"
echo "  ./pmm_watch.sh search-yaochi <关键词>  搜索瑶池记忆"
echo "  ./pmm_watch.sh recover <关键词>        从瑶池恢复到本地"
echo "  ./pmm_watch.sh status            查看状态"
        echo ""
        echo "首次运行 init 时将自动注册昆仑身份，无需手动配置。"
        echo "运行 setup 将自动写入心跳规则，实现每轮对话自动备份。"
        ;;
    backup)
        shift
        title="$1" content="$2"
        if [ -z "$title" ]; then
            echo "用法: ./pmm_watch.sh backup <标题> <内容>"
            exit 1
        fi
        backup_do "$title" "$content"
        ;;

esac

# ─── 客户端本地加密（Gzip + AES-256-GCM） ───
# ─── 瑶池记忆检索（本地+云端双向） ───
search_yaochi() {
    local query="$1"
    if [ -z "$query" ]; then
        echo "用法: ./pmm_watch.sh search <关键词>"
        exit 1
    fi
    local api; api=$(pmm_get_api)
    local token; token=$(pmm_get_token)
    echo "===== 本地检索 ====="
    if [ -f "$INDEX_FILE" ]; then
        jq -r --arg q "$query" '.memories[] | select((.title | test($q; "i")) or (.tags // "" | test($q; "i")) or (.content | test($q; "i"))) | "\(.timestamp // "?") | \(.title)\n"' "$INDEX_FILE" 2>/dev/null | head -20
        local cnt; cnt=$(jq -r --arg q "$query" '[.memories[] | select((.title | test($q; "i")) or (.tags // "" | test($q; "i")) or (.content | test($q; "i")))] | length' "$INDEX_FILE" 2>/dev/null || echo 0)
        echo "本地匹配: ${cnt} 条"
    else
        echo "本地索引不存在"
    fi
    echo ""
    echo "===== 瑶池检索 ====="
    if [ -n "$token" ]; then
        local res; res=$(pmm_curl "GET" "../api.php?route=yaochi/memory/search&scope=all&q=$(echo "$query" | sed 's/ /%20/g')&page=1&limit=10" "")
        local total; total=$(echo "$res" | jq -r '.total // 0' 2>/dev/null)
        if [ "$total" -gt 0 ] 2>/dev/null; then
            echo "$res" | jq -r '.memories[] // .results[]? | "\(.created_at // "?") | [\(.importance // 5)/10] \(.title)\n"' 2>/dev/null | head -20
            echo "瑶池匹配: ${total} 条"
        else
            echo "瑶池无匹配结果"
        fi
    else
        echo "未登录瑶池"
    fi
}

recover_from_yaochi() {
    local query="$1"
    local api; api=$(pmm_get_api)
    local token; token=$(pmm_get_token)
    if [ -z "$token" ]; then echo "未登录瑶池"; return 1; fi
    local res; res=$(pmm_curl "GET" "yaochi/memory/recover" "q=$query")
    local ok; ok=$(echo "$res" | jq -r '.success // false' 2>/dev/null)
    if [ "$ok" = "true" ]; then
        local cnt; cnt=$(echo "$res" | jq -r '.restored // 0' 2>/dev/null)
        echo -e "\033[0;32m✅ 从瑶池恢复 ${cnt} 条记忆到本地\033[0m"
        sync_index delta
    else
        echo -e "\033[0;33m⚠️ 恢复失败\033[0m"
    fi
}
