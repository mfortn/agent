#!/usr/bin/env bash
set -euo pipefail

CFG_SYS="/opt/agent/config/context.md"
SESS_DIR="/opt/agent/sessions"
PROJ_DIR="/opt/agent/projects.d"
MODEL="qwen2.5:7b-instruct-q4_0"

need() { command -v "$1" >/dev/null 2>&1 || { echo "⚠️ مطلوب تثبيت: $1"; exit 1; }; }
need curl
need jq

detect_model() {
  local m
  m="$(curl -sS http://127.0.0.1:11434/api/tags | jq -r '.models[0].model // empty' || true)"
  if [ -n "$m" ]; then echo "$m"; else echo "$MODEL"; fi
}
MODEL="$(detect_model)"

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

# ---------- اكتشاف الملفات من البرومبت ----------
guess_files_from_prompt() {
  local text="$1"; local root; root="$(project_root)"
  [ -n "$root" ] || { return 0; }
  local rx='[A-Za-z0-9_./-]+\.(vue|ts|js|tsx|jsx|py|go|php|md|json|yaml|yml|sh|css|html|ini|env)'
  matches=$(echo "$text" | grep -oE "$rx" | sort -u || true)
  if [ -n "$matches" ]; then
    while read -r token; do
      [ -n "$token" ] || continue
      if [ -f "$root/$token" ]; then echo "$root/$token"; continue; fi
      bn="$(basename "$token")"; find "$root" -type f -name "$bn" 2>/dev/null | head -n 1
    done <<< "$matches" | awk "NF"
    return 0
  fi
  # نبسّط تنظيف الرموز: ما نحتاج نمسك الـ backtick نهائيًا
  names=$(echo "$text" | sed "s/[،؛,.()\[\]{}<>'\"]/ /g" | tr -s ' ' | grep -oE "[A-Za-z0-9_-]+\\.vue" | sort -u || true)
  if [ -n "$names" ]; then
    while read -r bn; do
      [ -n "$bn" ] || continue
      find "$root" -type f -name "$bn" 2>/dev/null | head -n 1
    done <<< "$names" | awk "NF"
    return 0
  fi
  if echo "$text" | grep -qi "register"; then
    find "$root" -type f -iname "*register*.vue" 2>/dev/null | head -n 1
  fi
}

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
      rel="${f#$(project_root)/}"
      echo "--- path: ${rel:-$f} ---"
      head -c "$max_bytes" "$f" | tr -d '\r'
      echo
    done
    echo "[FILES CONTEXT END]"
  }
}

# نعرّف محدد الأسوار بدون كتابة رمز الـ backtick حرفيًا
FENCE="$(printf '\x60\x60\x60')"

extract_first_code_block() {
  awk -v fence="$FENCE" '
  BEGIN{in=0}
  index($0,fence)==1 {
    if (in==0) { in=1; next }
    else { exit }
  }
  in==1 { print }
  '
}

apply_code_to_file() {
  local target="$1"; local code="$2"
  [ -f "$target" ] || { echo "⚠️ الملف المستهدف غير موجود: $target"; return 1; }
  local ts; ts="$(date +%Y%m%d%H%M%S)"
  cp -f "$target" "${target}.bak.${ts}"
  printf "%s" "$code" > "$target"
  echo "✅ تم تحديث $(realpath "$target")"
  echo "🗃️ نسخة احتياطية: ${target}.bak.${ts}"
}

call_ollama() {
  local line="$1"
  local APPLY="0"
  if grep -q -- '--apply' <<<"$line"; then
    APPLY="1"
    line="$(sed 's/--apply//g' <<<"$line")"
  fi

  mapfile -t TARGETS < <(guess_files_from_prompt "$line")

  local system_prompt payload resp content prompt
  prompt="$(augment_with_files "$line")"
  system_prompt="$(build_system)"
  payload=$(jq -n --arg model "$MODEL" --arg system "$system_prompt" --arg user "$prompt" '{
    model:$model, stream:false,
    messages:[{role:"system",content:$system},{role:"user",content:$user}]
  }')

  resp="$(curl -sS http://127.0.0.1:11434/api/chat -d "$payload" || true)"
  if [ -z "$resp" ] || [ "$(echo "$resp" | jq -r '.error? // empty')" != "" ]; then
    echo "⚠️ فشل الاتصال بـ Ollama أو المودل غير متوفر: $MODEL"
    echo "نصائح:"
    echo " - sudo systemctl status ollama"
    echo " - curl -s http://127.0.0.1:11434/api/tags | jq"
    return 1
  fi

  content="$(echo "$resp" | jq -r '.message.content')"

  # سجل آمن عبر jq
  jq -n --arg u "$prompt"    '{role:"user",content:$u}'      >> "$HIST"
  jq -n --arg a "$content"   '{role:"assistant",content:$a}' >> "$HIST"

  echo; echo "$content"; echo

  if [ "$APPLY" = "1" ]; then
    if [ "${#TARGETS[@]}" -eq 0 ]; then
      echo "⚠️ --apply: لم أجد أي ملف في البرومبت لتطبيق التعديل عليه."
      return 0
    elif [ "${#TARGETS[@]}" -gt 1 ]; then
      echo "⚠️ --apply: تم العثور على عدة ملفات. رجاء حدد ملفًا واحدًا بدقة."
      printf 'الملفات:\n'; printf ' - %s\n' "${TARGETS[@]}"
      return 0
    fi
    local target="${TARGETS[0]}"
    local code
    code="$(printf "%s\n" "$content" | extract_first_code_block || true)"
    if [ -z "$code" ]; then
      echo "⚠️ --apply: لم أعثر على كتلة كود ضمن أسوار كود."
      echo "نصيحة: اطلب من النموذج أن يرجّع الملف كاملًا داخل أسوار كود."
      return 0
    fi
    apply_code_to_file "$target" "$code" || true
  fi
}

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
