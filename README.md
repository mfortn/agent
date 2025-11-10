# دليل إعداد الـAgent المحلي (Ubuntu + Ollama)

> هذا الدليل يشرح **من الصفر** كيف تجهز مساعدك المحلي (Co‑Owner) على Ubuntu Server باستخدام **Ollama** والموديل: **`qwen2.5:7b-instruct-q4_0`**.  
> الهدف: تقدر تتحاور معه عربيًا ويعرف مشاريعك تلقائيًا بدون رفع ملفات.

---

## المتطلبات المختصرة
- Ubuntu Server (أحدث إصدار متاح لديك).
- صلاحيات `sudo`.
- اتصال إنترنت وقت التثبيت فقط.

> ملاحظة: مكان مشاريعك الافتراضي في هذا الدليل هو `/workspace`. إذا كانت مشاريعك في مسار مختلف (مثل `/home/<user>/workspace`) غيّر القيمة في خطوة **[2.2 إعدادات الـAgent](#22-إعدادات-الـagent)**.

---

## 1) تثبيت Ollama وضبط الموديل

### 1.1 تثبيت Ollama
```bash
curl -fsSL https://ollama.com/install.sh | sh
sudo systemctl enable --now ollama
```

### 1.2 اختبار الموديل (تأكد من الوسم عندك)
```bash
ollama run qwen2.5:7b-instruct-q4_0
```
عند مطالبة النموذج اكتب أي طلب بسيط (مثال):
```
اكتب لي مثال كود بايثون يطبع hello world
/bye
```

### 1.3 جعل الموديل الافتراضي للنظام
```bash
echo "model: qwen2.5:7b-instruct-q4_0" | sudo tee /etc/ollama/config.yaml
sudo systemctl restart ollama
```

تحقق من وجود الموديل:
```bash
ollama list
```

---

## 2) تهيئة مجلد الـAgent

### 2.1 إنشاء المجلدات
```bash
sudo mkdir -p /opt/agent/{config,logs,memory,projects.d,sessions}
sudo chown -R "$USER:$USER" /opt/agent
```

### 2.2 إعدادات الـAgent
> غير `workspace_root` إذا كان مسارك مختلفًا (مثال: `/home/mfortn/workspace`).  
> الشرط الوحيد للتعرف على المشروع: وجود `api/` و`default/` وملف `.env` داخل كل مشروع.

أنشئ الملف: `/opt/agent/config/agent.yaml`
```bash
cat > /opt/agent/config/agent.yaml <<'YAML'
model: qwen2.5:7b-instruct-q4_0

# عدّل هذا المسار عند الحاجة
workspace_root: /home/mfortn/workspace

project_requirements:
  must_have_dirs: ["api", "default"]
  must_have_files: [".env"]

conversation:
  language: "ar"
  style: "طبيعي ومباشر"
  max_context_tokens: 8192

logging:
  dir: "/opt/agent/logs"
  rotate_megabytes: 50
  keep: 10

memory:
  dir: "/opt/agent/memory"

sessions:
  dir: "/opt/agent/sessions"
YAML
```

### 2.3 ملف السياق (اختياري لكنه مفيد)
`/opt/agent/config/context.md`
```bash
cat > /opt/agent/config/context.md <<'MD'
# سياق العمل للـAgent
- أنت تعمل على Ubuntu Server.
- المودل: Qwen 2.5 7B Instruct (Q4_0) عبر Ollama.
- المشاريع ضمن workspace_root وتحتوي api/ و default/ و .env.
- لغة الحوار: العربية.
- دورك: Co-Owner يراجع الكود، يقترح تحسينات، يشرح ويعلّق.
- إن واجهت نقص صلاحية أو أمر يحتاج تنفيذ: اطلب "تمت تقدر تدخل الان" ثم أوضح المطلوب.
MD
```

---

## 3) أدوات مساعدة

### 3.1 `agentctl` (اختياري)
```bash
cat > /opt/agent/agentctl <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  cfg)   cat /opt/agent/config/agent.yaml ;;
  ctx)   cat /opt/agent/config/context.md ;;
  list)  ls -1 /opt/agent/projects.d || true ;;
  paths)
    root="$(grep -E '^workspace_root:' /opt/agent/config/agent.yaml 2>/dev/null | awk '{print $2}')"
    echo "root=${root:-/workspace}  agent=/opt/agent"
    ;;
  *) echo "Usage: agentctl {cfg|ctx|list|paths}" ;;
esac
BASH
chmod +x /opt/agent/agentctl
```

### 3.2 اكتشاف وربط المشاريع
هذا السكربت يمر على كل مجلد داخل `workspace_root`، ويضيف رابطًا رمزيًا لكل مشروع مستوفٍ للشروط.
```bash
cat > /opt/agent/bin-discover-projects.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

CFG="/opt/agent/config/agent.yaml"
WS="$(grep -E '^workspace_root:' "$CFG" 2>/dev/null | awk '{print $2}')"
WS="${WS:-/workspace}"
DEST="/opt/agent/projects.d"

mkdir -p "$DEST"

found=0
for proj in "$WS"/*; do
  [ -d "$proj" ] || continue
  name="$(basename "$proj")"

  if [ -d "$proj/api" ] && [ -d "$proj/default" ] && [ -f "$proj/.env" ]; then
    ln_target="$DEST/$name"
    if [ -L "$ln_target" ] || [ -e "$ln_target" ]; then
      echo "✔ موجود: $name"
    else
      ln -s "$proj" "$ln_target"
      echo "＋ أُضيف: $name"
    fi
    found=$((found+1))
  else
    echo "✖ يتخطى: $name (ناقص api/ أو default/ أو .env)"
  fi
done

echo "المشاريع المعتمدة: $found"
BASH
chmod +x /opt/agent/bin-discover-projects.sh
```

تشغيله:
```bash
/opt/agent/bin-discover-projects.sh
/opt/agent/agentctl list
```

> تقدر تشغله يدويًا كل ما تضيف مشروع جديد، أو تضيفه لـ cron لو حبيت.

---

## 4) تشغيل جلسة المحادثة (TUI)

### 4.1 تثبيت أداة JSON
```bash
sudo apt-get update && sudo apt-get install -y jq
```

### 4.2 سكربت المحادثة
```bash
cat > /opt/agent/agent-chat <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

CFG_SYS="/opt/agent/config/context.md"
SESS_DIR="/opt/agent/sessions"
PROJ_DIR="/opt/agent/projects.d"
MODEL="$(grep -E '^model:' /etc/ollama/config.yaml 2>/dev/null | awk '{print $2}')"
MODEL="${MODEL:-qwen2.5:7b-instruct-q4_0}"

mkdir -p "$SESS_DIR"
SESSION_ID="$(date +"%Y%m%d-%H%M%S")"
HIST="$SESS_DIR/$SESSION_ID.jsonl"
touch "$HIST"

SYSTEM="$(cat "$CFG_SYS" 2>/dev/null || true)"
CURRENT_PROJ=""

say_help() { echo "أوامر: :projects | :use <project> | :reset | :quit"; }
list_projects() { ls -1 "$PROJ_DIR" 2>/dev/null | sort -u; }

build_system() {
  local sys="$SYSTEM"
  if [ -n "$CURRENT_PROJ" ]; then
    sys="$sys

# المشروع المحدد
- المشروع: $CURRENT_PROJ
- المسار: $(readlink -f "$PROJ_DIR/$CURRENT_PROJ" 2>/devالnull || echo "$PROJ_DIR/$CURRENT_PROJ")
- بنية المشروع: يحتوي api/ و default/ و ملف .env.
"
  fi
  printf "%s" "$sys"
}

reset_session() { : > "$HIST"; echo "تمت إعادة تعيين المحادثة."; }

call_ollama() {
  local prompt="$1"
  local system_prompt
  system_prompt="$(build_system)"
  local payload
  payload=$(jq -n --arg model "$MODEL" --arg system "$system_prompt" --arg user "$prompt" '{
    model:$model,stream:false,
    messages:[{role:"system",content:$system},{role:"user",content:$user}]
  }')
  local resp
  resp="$(curl -sS http://127.0.0.1:11434/api/chat -d "$payload")" || { echo "⚠️ فشل الاتصال بـ Ollama."; return 1; }
  local content
  content="$(echo "$resp" | jq -r '.message.content')"
  echo "{\"role\":\"user\",\"content\":$(jq -Rs . <<<"$prompt")}"  >> "$HIST"
  echo "{\"role\":\"assistant\",\"content\":$(jq -Rs . <<<"$content")}" >> "$HIST"
  echo; echo "$content"; echo
}

echo "جلسة Agent: $SESSION_ID  |  المودل: $MODEL"
say_help
[ -ف "$CFG_SYS" ] || echo "⚠️ ملف السياق غير موجود."

while true; do
  read -rp "أنت: " line || exit 0
  case "$line" in
    ":quit"|":q") echo "مع السلامة 👋"; exit 0 ;;
    ":projects")  list_projects; continue ;;
    ":reset")     reset_session; continue ;;
    ":use "*)     name="${line#:use }"
                  if [ -L "$PROJ_DIR/$name" ] || [ -d "$PROJ_DIR/$name" ]; then
                    CURRENT_PROJ="$name"; echo "تم اختيار المشروع: $CURRENT_PROJ"
                  else
                    echo "لم أجد مشروعاً بهذا الاسم."
                  fi
                  continue ;;
    ":help"|":h") say_help; continue ;;
  esac
  [ -n "$line" ] || continue
  call_ollama "$line"
done
BASH
chmod +x /opt/agent/agent-chat
```

### 4.3 الإطلاق
```bash
/opt/agent/agent-chat
```
داخل الجلسة:
- `:projects` لعرض المشاريع المكتشفة
- `:use <project>` لاختيار مشروع
- `:reset` لإعادة تهيئة المحادثة
- `:quit` للخروج

> أي أمر يحتاج تنفيذ فعلي (git, artisan, npm, …) سيُقترح عليك كتوجيه، وتنفذه أنت يدويًا.

---

## 5) استكشاف الأخطاء السريعة

- **الجلسة تخرج مباشرة؟**
  - تأكد من صلاحية التنفيذ:
    ```bash
    sudo chmod +x /opt/agent/agent-chat
    ```
  - تأكد من أن خدمة Ollama تعمل:
    ```bash
    sudo systemctl status ollama
    curl -s http://127.0.0.1:11434/api/tags | jq
    ```

- **المشاريع لا تظهر؟**
  - تأكد من المسار في `agent.yaml` (المفتاح `workspace_root`).
  - شغل الاكتشاف:
    ```bash
    /opt/agent/bin-discover-projects.sh
    /opt/agent/agentctl list
    ```

---

### تم 👍
الآن لديك Agent محلي يعمل بالموديل **`qwen2.5:7b-instruct-q4_0`**، يعرف مشاريعك تلقائيًا، وتقدر تتحاور معه بالعربية داخل الطرفية.
