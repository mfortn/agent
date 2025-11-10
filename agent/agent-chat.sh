#!/usr/bin/env bash
# agent-chat.sh — جلسة محادثة محلية مع Ollama ودعم --apply لتعديل الملفات
set -euo pipefail

# ======================= الإعدادات العامة =======================
CFG_SYS="/opt/agent/config/context.md"   # ملف سياق النظام الذي يُرسل للمودل
SESS_DIR="/opt/agent/sessions"           # مجلد سجلات الجلسات JSONL
PROJ_DIR="/opt/agent/projects.d"         # جذر المشاريع
MODEL="qwen2.5:7b-instruct-q4_0"         # مودل افتراضي إذا فشل auto-detect

# ======================= متطلبات التشغيل ========================
need() { command -v "$1" >/dev/null 2>&1 || { echo "⚠️ مطلوب تثبيت: $1"; exit 1; }; }
need curl
need jq
need python3

# ======================= كشف المودل تلقائيًا ====================
detect_model() {
  local m
  m="$(curl -sS http://127.0.0.1:11434/api/tags | jq -r '.models[0].model // empty' || true)"
  if [ -n "$m" ]; then echo "$m"; else echo "$MODEL"; fi
}
MODEL="$(detect_model)"

# ======================= تهيئة الجلسة ===========================
mkdir -p "$SESS_DIR"
SESSION_ID="$(date +"%Y%m%d-%H%M%S")"
HIST="$SESS_DIR/$SESSION_ID.jsonl"
: > "$HIST"

SYSTEM="$(cat "$CFG_SYS" 2>/dev/null || true)"
CURRENT_PROJ=""

say_help() { echo "أوامر: :projects | :use <project> | :reset | :help | :quit"; }
list_projects() { ls -1 "$PROJ_DIR" 2>/dev/null | sort -u || true; }

project_root() {
  [ -n "${CURRENT_PROJ:-}" ] || { echo ""; return 0; }
  readlink -f "$PROJ_DIR/$CURRENT_PROJ" 2>/dev/null || echo "$PROJ_DIR/$CURRENT_PROJ"
}

build_system() {
  local sys="$SYSTEM"
  if [ -n "$CURRENT_PROJ" ]; then
    sys="$sys

# المشروع المحدد
- المشروع: $CURRENT_PROJ
- المسار: $(project_root)
"
  fi
  printf "%s" "$sys"
}

reset_session() { : > "$HIST"; echo "تمت إعادة تعيين المحادثة."; }

# ======================= أدوات البحث مع استثناءات ===============
# استثناء مجلدات ثقيلة/غير مناسبة للتعديل
PRUNE_DIRS=(-path '*/vendor/*' -o -path '*/node_modules/*' -o -path '*/.git/*' -o -path '*/dist/*' -o -path '*/build/*')

safe_find_first() {
  # usage: safe_find_first <root> <pattern-name>
  local root="$1"; local name="$2"
  find "$root" \( "${PRUNE_DIRS[@]}" \) -prune -o -type f -name "$name" -print 2>/dev/null
}

# ======================= اكتشاف الملفات من البرومبت =============
guess_files_from_prompt() {
  local text="$1"; local root; root="$(project_root)"
  [ -n "$root" ] || { return 0; }

  local candidates=()

  # 1) مسارات كاملة بأمتدادات شائعة
  local rx='[A-Za-z0-9_./-]+\.(vue|ts|js|tsx|jsx|py|go|php|md|json|yaml|yml|sh|css|html|ini|env)'
  local matches; matches=$(echo "$text" | grep -oE "$rx" | sort -u || true)
  if [ -n "${matches:-}" ]; then
    while read -r token; do
      [ -n "$token" ] || continue
      if [ -f "$root/$token" ]; then
        candidates+=("$root/$token")
        continue
      fi
      local bn; bn="$(basename "$token")"
      while read -r p; do
        [ -n "$p" ] && candidates+=("$p")
      done < <(safe_find_first "$root" "$bn")
    done <<< "$matches"
  fi

  # 2) أسماء .vue مكتوبة نصًا
  local names; names=$(echo "$text" | sed "s/[،؛,.()\[\]{}<>'\"]/ /g" | tr -s ' ' | grep -oE "[A-Za-z0-9_-]+\\.vue" | sort -u || true)
  if [ -n "${names:-}" ]; then
    while read -r bn; do
      [ -n "$bn" ] || continue
      while read -r p; do
        [ -n "$p" ] && candidates+=("$p")
      done < <(safe_find_first "$root" "$bn")
    done <<< "$names"
  fi

  # 3) تلميح register لو ما لقينا شي
  if [ "${#candidates[@]}" -eq 0 ] && echo "$text" | grep -qi "register"; then
    while read -r p; do
      [ -n "$p" ] && candidates+=("$p")
    done < <(find "$root" \( "${PRUNE_DIRS[@]}" \) -prune -o -type f -iname "*register*.vue" -print 2>/dev/null)
  fi

  # لا شيء؟
  [ "${#candidates[@]}" -gt 0 ] || return 0

  # إزالة تكرار
  # shellcheck disable=SC2207
  candidates=($(printf "%s\n" "${candidates[@]}" | awk '!x[$0]++'))

  # ============ أولوية الاختيار ============
  # 1) داخل default/ وامتداد .vue
  # 2) داخل default/ (أي ملف)
  # 3) أي .vue ليس في api/ ولا vendor/node_modules
  # 4) الباقي
  declare -a tier1=() tier2=() tier3=() tier4=()
  local p
  for p in "${candidates[@]}"; do
    case "$p" in
      *"/default/"*".vue") tier1+=("$p") ;;
      *"/default/"*)       tier2+=("$p") ;;
      *".vue")
        if [[ "$p" != *"/api/"* ]]; then tier3+=("$p"); else tier4+=("$p"); fi
        ;;
      *) tier4+=("$p") ;;
    esac
  done

  if   [ "${#tier1[@]}" -gt 0 ]; then printf "%s\n" "${tier1[@]}"; return 0
  elif [ "${#tier2[@]}" -gt 0 ]; then printf "%s\n" "${tier2[@]}"; return 0
  elif [ "${#tier3[@]}" -gt 0 ]; then printf "%s\n" "${tier3[@]}"; return 0
  else printf "%s\n" "${tier4[@]}"; return 0
  fi
}

# ======================= ضم محتوى الملفات للسياق ================
augment_with_files() {
  local prompt="$1"; local files=(); local count=0; local max_files=5; local max_bytes=81920
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    files+=("$f"); count=$((count+1))
    [ "$count" -ge "$max_files" ] && break
  done < <(guess_files_from_prompt "$prompt")

  [ "${#files[@]}" -gt 0 ] || { printf "%s" "$prompt"; return 0; }

  {
    echo "$prompt"
    echo
    echo "[FILES CONTEXT START]"
    for f in "${files[@]}"; do
      local rel; rel="${f#$(project_root)/}"
      echo "--- path: ${rel:-$f} ---"
      head -c "$max_bytes" "$f" | tr -d '\r'
      echo
    done
    echo "[FILES CONTEXT END]"
  }
}

# ======================= استخراج أول كتلة كود (Python) ==========
extract_first_code_block() {
  python3 - "$@" <<'PY'
import sys, re
text = sys.stdin.read()

# التقط أول fenced code block (``` ... ```) أو (~~~ ... ~~~)
m = re.search(r"```[^\n]*\n([\s\S]*?)\n```", text)
if not m:
    m = re.search(r"~~~[^\n]*\n([\s\S]*?)\n~~~", text)

if m:
    code = m.group(1).lstrip()
    # أحيانًا يرجع السطر الأول "vue" ضمن المحتوى؛ قصّه إن وجد.
    if code.startswith('vue'):
        code = code[3:].lstrip()
    sys.stdout.write(code)
PY
}

# ======================= استخراج قسم من ملف Vue (Python) ========
extract_vue_section() {
  # usage: extract_vue_section <file_path> <tagname>
  # أمثلة: extract_vue_section path.vue script  |  extract_vue_section path.vue template
  local f="$1"; local tag="$2"
  [ -f "$f" ] || return 1
  python3 - "$f" "$tag" <<'PY'
import sys, re, pathlib
path = pathlib.Path(sys.argv[1])
tag  = sys.argv[2].lower()
txt  = path.read_text(encoding="utf-8", errors="replace")
# التقط أقرب زوج مطابق مثل <script ...> ... </script>
m = re.search(rf"<{tag}(\s[^>]*)?>\s*([\s\S]*?)\s*</{tag}>", txt, re.IGNORECASE)
if m:
    # أعِد الجسم الداخلي للقسم فقط بدون وسم الفتح/الإغلاق
    sys.stdout.write(m.group(0))
PY
}

# ======================= تطبيق الكود على الملف ===================
apply_code_to_file() {
  local target="$1"; local code="$2"
  [ -f "$target" ] || { echo "⚠️ الملف المستهدف غير موجود: $target"; return 1; }
  local ts; ts="$(date +%Y%m%d%H%M%S)"
  cp -f "$target" "${target}.bak.${ts}"
  printf "%s" "$code" > "$target"
  echo "✅ تم تحديث $(realpath "$target")"
  echo "🗃️ نسخة احتياطية: ${target}.bak.${ts}"
}

# ======================= استدعاء Ollama وتنسيق الرد =============
call_ollama() {
  local line="$1"
  local APPLY="0"
  local RADICAL="0"

  # التعرّف على الفلاقز
  if grep -q -- '--apply' <<<"$line"; then
    APPLY="1"
    line="$(sed 's/--apply//g' <<<"$line")"
  fi
  if grep -q -- '--radical' <<<"$line"; then
    RADICAL="1"
    line="$(sed 's/--radical//g' <<<"$line")"
  fi

  # قواعد إخراج صارمة (وتثبيت ترتيب الأقسام ومنع نسخ البُنية/الكلاسات)
  read -r -d '' OUTPUT_RULES_BASE <<'RULES'
[OUTPUT RULES]
- أعد الملف المستهدف كاملًا داخل كتلة كود واحدة محاطة بـ ``` (يمكن تحديد اللغة مثل ```vue).
- حافظ على **ترتيب الأقسام كما هي** (مثل <template> ثم <script> ثم <style>) ولا تغيّر مواقعها.
- لا تكتب أي شرح أو نص خارج كتلة الكود.
- إن كان بالملف <script>، انسخ القسم كما هو وعدّل فقط <template> و/أو <style> إذا طُلب.
- حافظ على جميع ارتباطات v-model و @events كما هي بدون تغيير.
RULES

  # قواعد إضافية خاصة بالراديكالي
  local OUTPUT_RULES="$OUTPUT_RULES_BASE"
  if [ "$RADICAL" = "1" ]; then
    read -r -d '' OUTPUT_RULES_EXTRA <<'R2'
- إعادة تصميم جذرية من الصفر لواجهة المستخدم (لا تعِد استخدام نفس التخطيطات أو أسماء الكلاسات أو الأنماط السابقة).
- ابتكر بنية واجهة جديدة تمامًا (layout جديد، hierarchy جديدة، spacing/type جديدة) مع الالتزام بمنطق التسجيل الحالي.
R2
    OUTPUT_RULES="$OUTPUT_RULES

$OUTPUT_RULES_EXTRA"
  fi

  # تحديد الهدف/الأهداف من البرومبت
  mapfile -t TARGETS < <(guess_files_from_prompt "$line")

  # تجهيز الـ prompt + السياق
  local system_prompt payload resp content prompt files_context
  system_prompt="$(build_system)"

  # في الوضع الراديكالي لملف Vue: نُرسل قسم <script> فقط كمرجع، ونخفي بقية الواجهة
  if [ "$RADICAL" = "1" ] && [ "${#TARGETS[@]}" -eq 1 ] && [[ "${TARGETS[0]}" == *.vue ]]; then
    local t="${TARGETS[0]}"
    local script_block
    script_block="$(extract_vue_section "$t" "script" || true)"
    if [ -n "$script_block" ]; then
      files_context=$(
        cat <<CTX
$line

$OUTPUT_RULES

[FILES CONTEXT START - RADICAL SCRIPT ONLY]
--- path: ${t#$(project_root)/} (script only) ---
$script_block
[FILES CONTEXT END]
CTX
      )
    else
      # fallback: لو ما قدرنا نلقط السكربت لأي سبب، نضم الملف كاملًا
      files_context="$line

$OUTPUT_RULES

$(augment_with_files "$line")"
    fi
  else
    # الوضع العادي: ضم الملفات كاملة
    files_context="$line

$OUTPUT_RULES

$(augment_with_files "$line")"
  fi

  prompt="$files_context"

  # خيارات توليد أعلى تنوّع + بذرة عشوائية لكل طلب (للاختلاف الحقيقي بين محاولات متعددة)
  local SEED; SEED=$(( (RANDOM<<16) ^ RANDOM ^ $(date +%s) ))
  payload=$(jq -n \
    --arg model "$MODEL" \
    --arg system "$system_prompt" \
    --arg user "$prompt" \
    --argjson seed "$SEED" \
    '{
      model:$model,
      stream:false,
      options:{temperature:1.1, top_p:0.95, top_k:50, repetition_penalty:1.1, seed:$seed, num_predict:-1},
      messages:[{role:"system",content:$system},{role:"user",content:$user}]
    }')

  # الاستدعاء
  resp="$(curl -sS http://127.0.0.1:11434/api/chat -d "$payload" || true)"
  if [ -z "$resp" ] || [ "$(echo "$resp" | jq -r '.error? // empty')" != "" ]; then
    echo "⚠️ فشل الاتصال بـ Ollama أو المودل غير متوفر: $MODEL"
    echo "نصائح:"
    echo " - sudo systemctl status ollama"
    echo " - curl -s http://127.0.0.1:11434/api/tags | jq"
    return 1
  fi

  content="$(echo "$resp" | jq -r '.message.content')"

  # تسجيل آمن عبر jq
  jq -n --arg u "$prompt"    '{role:"user",content:$u}'      >> "$HIST"
  jq -n --arg a "$content"   '{role:"assistant",content:$a}' >> "$HIST"

  # عرض الرد للمستخدم كما هو
  echo; echo "$content"; echo

  # وضع التطبيق الفعلي
  if [ "$APPLY" = "1" ]; then
    if [ "${#TARGETS[@]}" -eq 0 ]; then
      echo "⚠️ --apply: لم أجد أي ملف في البرومبت لتطبيق التعديل عليه."
      return 0
    elif [ "${#TARGETS[@]}" -gt 1 ]; then
      echo "⚠️ --apply: تم العثور على عدة ملفات. رجاءً حدّد ملفًا واحدًا بدقة."
      printf 'الملفات:\n'; printf ' - %s\n' "${TARGETS[@]}"
      return 0
    fi

    local target="${TARGETS[0]}"
    local code
    code="$(printf "%s\n" "$content" | extract_first_code_block || true)"

    if [ -z "$code" ]; then
      # ✨ خطة بديلة: لو الرد واضح إنه كود، نستخدمه مباشرة
      if grep -qiE '<template|</template>|<script|</script>|<style|class\s+\w+|function\s+\w+|export\s+default' <<<"$content"; then
        code="$content"
      fi
    fi

    if [ -z "$code" ]; then
      echo "⚠️ --apply: لم أعثر على كتلة كود ضمن أسوار كود."
      echo "نصيحة: اطلب من النموذج أن يرجّع الملف كاملًا داخل أسوار كود."
      return 0
    fi

    apply_code_to_file "$target" "$code" || true
  fi
}

# ======================= واجهة النص التفاعلية ====================
echo "جلسة Agent: $SESSION_ID  |  المودل: $MODEL"
[ -f "$CFG_SYS" ] || echo "⚠️ ملاحظة: ملف السياق غير موجود: $CFG_SYS"
say_help

while true; do
  read -rp "أنت: " line || exit 0

  if [[ "$line" =~ ^:use[[:space:]]+(.+)$ ]]; then
    name="$(echo "${BASH_REMATCH[1]}" | awk '{$1=$1;print}')"
    if [ -e "$PROJ_DIR/$name" ]; then
      CURRENT_PROJ="$name"; echo "تم اختيار المشروع: $CURRENT_PROJ"
    else
      echo "لم أجد مشروعاً بهذا الاسم: $name"
    fi
    continue
  fi

  case "$line" in
    ":quit"|":q") echo "مع السلامة 👋"; exit 0 ;;
    ":projects")  list_projects; continue ;;
    ":reset")     reset_session; continue ;;
    ":help"|":h") say_help; continue ;;
  esac

  [ -n "$line" ] || continue
  call_ollama "$line" || true
done
