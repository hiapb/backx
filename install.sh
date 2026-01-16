#!/usr/bin/env bash
set -euo pipefail

# =========================
# RelayX Backup & Restore
# =========================

# ---- Defaults (can override with env) ----
DEFAULT_RELAYX_DIR="/root/relayx"

MYSQL_CONTAINER="${MYSQL_CONTAINER:-mysql}"
REDIS_CONTAINER="${REDIS_CONTAINER:-redis}"

# Backup bundle names (overwrite each time)
SITE_BUNDLE_NAME="site_backup_latest.tar.gz"
DATA_BUNDLE_NAME="data_backup_latest.tar.gz"

# Site files expected in relayx dir
SITE_FILES=("compose.yaml" ".env" "Caddyfile")

# Cron file (root)
CRON_FILE="/etc/cron.d/relayx-backup"

# ---- Utilities ----
require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }; }

normalize_choice() {
  # remove leading zeros; "01" -> "1"; empty -> empty
  local x="${1:-}"
  x="${x#"${x%%[!0]*}"}" || true
  [[ -z "$x" ]] && echo "" || echo "$x"
}

info() { echo -e "$*"; }
warn() { echo -e "WARN: $*" >&2; }
die() { echo -e "ERROR: $*" >&2; exit 1; }

# Find relayx directory:
# 1) RELAYX_DIR env
# 2) current dir or parents containing compose.yaml
# 3) default /root/relayx
find_relayx_dir() {
  if [[ -n "${RELAYX_DIR:-}" ]]; then
    echo "$RELAYX_DIR"
    return
  fi

  local d="$PWD"
  while [[ "$d" != "/" ]]; do
    if [[ -f "$d/compose.yaml" ]]; then
      echo "$d"
      return
    fi
    d="$(dirname "$d")"
  done

  if [[ -f "$DEFAULT_RELAYX_DIR/compose.yaml" ]]; then
    echo "$DEFAULT_RELAYX_DIR"
    return
  fi

  die "找不到 relayx 目录。请在 relayx 目录执行，或设置环境变量 RELAYX_DIR=/root/relayx"
}

ensure_site_files_exist() {
  local workdir="$1"
  local missing=0
  for f in "${SITE_FILES[@]}"; do
    if [[ ! -f "$workdir/$f" ]]; then
      echo "缺少文件：$workdir/$f"
      missing=1
    fi
  done
  [[ $missing -eq 0 ]] || die "请确认 compose.yaml / .env / Caddyfile 都在 relayx 目录。"
}

compose_in_dir() {
  local workdir="$1"
  shift
  (cd "$workdir" && docker compose "$@")
}

container_exists() {
  local name="$1"
  docker ps -a --format '{{.Names}}' | grep -qx "$name"
}

# Wait MySQL ready (best-effort)
wait_mysql_ready() {
  local tries=30
  local i=1
  while [[ $i -le $tries ]]; do
    if docker exec "$MYSQL_CONTAINER" sh -c 'mysqladmin ping -h 127.0.0.1 -uroot -p"$MYSQL_ROOT_PASSWORD" --silent' >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    i=$((i+1))
  done
  return 1
}

# MySQL dump command (GTID-safe)
mysql_dump_cmd() {
  # --set-gtid-purged=OFF 解决 GTID 警告/恢复兼容性问题
  cat <<'EOF'
mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" \
  --single-transaction \
  --set-gtid-purged=OFF \
  --routines --triggers \
  --databases relayx
EOF
}

# ---- Backup (ONLINE, no downtime) ----
backup_full_online() {
  local workdir="$1"
  ensure_site_files_exist "$workdir"

  local backup_dir="$workdir/backup_latest_site"
  local bundle="$workdir/$SITE_BUNDLE_NAME"

  rm -rf "$backup_dir"
  mkdir -p "$backup_dir/site_files" "$backup_dir/db" "$backup_dir/meta"

  info "\n== 整站备份（在线，不暂停；覆盖整站包）=="
  info "[1/4] 复制站点文件..."
  for f in "${SITE_FILES[@]}"; do
    cp -f "$workdir/$f" "$backup_dir/site_files/"
  done

  info "[2/4] 在线导出 MySQL（事务一致）..."
  container_exists "$MYSQL_CONTAINER" || die "找不到 MySQL 容器：$MYSQL_CONTAINER"
  docker exec "$MYSQL_CONTAINER" sh -c "$(mysql_dump_cmd)" | gzip -9 > "$backup_dir/db/relayx.sql.gz"

  info "[3/4] Redis（可选）：触发 BGSAVE（不暂停）..."
  if container_exists "$REDIS_CONTAINER"; then
    docker exec "$REDIS_CONTAINER" sh -c 'redis-cli BGSAVE >/dev/null 2>&1 || true'
  else
    warn "未找到 Redis 容器：$REDIS_CONTAINER，跳过"
  fi

  info "[4/4] 打包整站备份 -> $bundle"
  date +"backup_time=%F_%H%M%S" > "$backup_dir/meta/manifest.txt"
  cat >> "$backup_dir/meta/manifest.txt" <<EOF
type=full_online
workdir=$workdir
bundle=$bundle
EOF

  rm -f "$bundle"
  tar -czf "$bundle" -C "$workdir" "$(basename "$backup_dir")"

  info "✅ 整站在线备份完成：$bundle\n"
}

backup_data_online() {
  local workdir="$1"
  ensure_site_files_exist "$workdir"

  local backup_dir="$workdir/backup_latest_data"
  local bundle="$workdir/$DATA_BUNDLE_NAME"

  rm -rf "$backup_dir"
  mkdir -p "$backup_dir/db" "$backup_dir/meta"

  info "\n== 数据备份（在线，不暂停；覆盖数据包）=="
  info "[1/2] 在线导出 MySQL（事务一致）..."
  container_exists "$MYSQL_CONTAINER" || die "找不到 MySQL 容器：$MYSQL_CONTAINER"
  docker exec "$MYSQL_CONTAINER" sh -c "$(mysql_dump_cmd)" | gzip -9 > "$backup_dir/db/relayx.sql.gz"

  info "[可选] Redis：触发 BGSAVE（不暂停）..."
  if container_exists "$REDIS_CONTAINER"; then
    docker exec "$REDIS_CONTAINER" sh -c 'redis-cli BGSAVE >/dev/null 2>&1 || true'
  fi

  date +"backup_time=%F_%H%M%S" > "$backup_dir/meta/manifest.txt"
  cat >> "$backup_dir/meta/manifest.txt" <<EOF
type=data_online
workdir=$workdir
bundle=$bundle
EOF

  info "[2/2] 打包数据备份 -> $bundle"
  rm -f "$bundle"
  tar -czf "$bundle" -C "$workdir" "$(basename "$backup_dir")"

  info "✅ 数据在线备份完成：$bundle\n"
}

# ---- Restore (ALLOW downtime) ----
restore_data_default_then_optional_full() {
  local workdir="$1"
  local data_bundle="$workdir/$DATA_BUNDLE_NAME"
  local site_bundle="$workdir/$SITE_BUNDLE_NAME"

  info "\n== 恢复菜单（先数据，再整站）=="

  # 先优先问：是否用数据恢复（默认 y）
  if [[ -f "$data_bundle" ]]; then
    read -r -p "是否使用【数据恢复】（推荐，导入 data_backup）？(Y/n): " ans_data
    if [[ -z "${ans_data:-}" || "${ans_data:-}" =~ ^[Yy]$ ]]; then
      restore_data_from_data_bundle "$workdir"
      return
    fi
  else
    warn "未找到数据备份包：$data_bundle"
    # 没有数据包就直接进入整站选择
  fi

  # 数据恢复选了否，或者压根没有数据包 → 再提示整站
  if [[ -f "$site_bundle" ]]; then
    read -r -p "是否改用【整站恢复】（导入 site_backup，覆盖配置+数据库）？(y/N): " ans_site
    if [[ "${ans_site:-}" =~ ^[Yy]$ ]]; then
      restore_full_from_site_bundle "$workdir"
      return
    fi
  else
    warn "未找到整站备份包：$site_bundle"
  fi

  die "没有可用的恢复来源（既没有数据包也没有整站包）。"
}

restore_data_from_data_bundle() {
  local workdir="$1"
  local data_bundle="$workdir/$DATA_BUNDLE_NAME"

  [[ -f "$data_bundle" ]] || die "找不到数据备份包：$data_bundle（请先做一次“数据备份”）"

  info "\n== 数据恢复（使用数据备份包）=="
  read -r -p "确认恢复数据库？会覆盖当前数据库。输入 YES 继续: " ans
  [[ "$ans" == "YES" ]] || { info "已取消。\n"; return; }

  info "[1/5] 停止服务..."
  compose_in_dir "$workdir" down || true

  info "[2/5] 解包数据备份..."
  local tmpdir="$workdir/_restore_tmp_data"
  rm -rf "$tmpdir"
  mkdir -p "$tmpdir"
  tar -xzf "$data_bundle" -C "$tmpdir"

  local extracted
  extracted="$(find "$tmpdir" -maxdepth 1 -type d -name 'backup_latest_data' -print -quit || true)"
  [[ -n "$extracted" ]] || die "解包失败：找不到 backup_latest_data 目录"

  info "[3/5] 启动 MySQL（用于导入）..."
  compose_in_dir "$workdir" up -d mysql

  if ! wait_mysql_ready; then
    warn "MySQL 可能尚未就绪，继续尝试导入（如失败请再试一次）"
  fi

  info "[4/5] 导入数据库（覆盖 relayx）..."
  gunzip -c "$extracted/db/relayx.sql.gz" | docker exec -i "$MYSQL_CONTAINER" sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"'

  info "[5/5] 启动全栈..."
  compose_in_dir "$workdir" up -d
  compose_in_dir "$workdir" ps

  rm -rf "$tmpdir"
  info "✅ 数据恢复完成\n"
}

restore_full_from_site_bundle() {
  local workdir="$1"
  local site_bundle="$workdir/$SITE_BUNDLE_NAME"
  [[ -f "$site_bundle" ]] || die "找不到整站备份包：$site_bundle（请先做一次“整站备份”）"

  info "\n== 整站恢复（使用整站备份包）=="
  read -r -p "确认整站恢复？会覆盖当前配置+数据库。输入 YES 继续: " ans
  [[ "$ans" == "YES" ]] || { info "已取消。\n"; return; }

  info "[1/6] 停止服务..."
  compose_in_dir "$workdir" down || true

  info "[2/6] 解包整站备份..."
  local tmpdir="$workdir/_restore_tmp_site"
  rm -rf "$tmpdir"
  mkdir -p "$tmpdir"
  tar -xzf "$site_bundle" -C "$tmpdir"

  local extracted
  extracted="$(find "$tmpdir" -maxdepth 1 -type d -name 'backup_latest_site' -print -quit || true)"
  [[ -n "$extracted" ]] || die "解包失败：找不到 backup_latest_site 目录"

  info "[3/6] 恢复站点文件（覆盖当前）..."
  for f in "${SITE_FILES[@]}"; do
    if [[ -f "$extracted/site_files/$f" ]]; then
      cp -f "$extracted/site_files/$f" "$workdir/$f"
    fi
  done

  info "[4/6] 启动 MySQL（用于导入）..."
  compose_in_dir "$workdir" up -d mysql
  if ! wait_mysql_ready; then
    warn "MySQL 可能尚未就绪，继续尝试导入（如失败请再试一次）"
  fi

  info "[5/6] 导入数据库（覆盖 relayx）..."
  gunzip -c "$extracted/db/relayx.sql.gz" | docker exec -i "$MYSQL_CONTAINER" sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"'

  info "[6/6] 启动全栈..."
  compose_in_dir "$workdir" up -d
  compose_in_dir "$workdir" ps

  rm -rf "$tmpdir"
  info "✅ 整站恢复完成\n"
}

# ---- Status ----
show_status() {
  local workdir="$1"
  info "\nDocker Compose 状态："
  compose_in_dir "$workdir" ps || true

  info "\n备份包："
  [[ -f "$workdir/$SITE_BUNDLE_NAME" ]] && ls -lah "$workdir/$SITE_BUNDLE_NAME" || echo "  (无整站备份包)"
  [[ -f "$workdir/$DATA_BUNDLE_NAME" ]] && ls -lah "$workdir/$DATA_BUNDLE_NAME" || echo "  (无数据备份包)"

  info "\n提示：把 *.tar.gz 记得额外备份到异地（NAS/另一台机/对象存储）。\n"
}

# ---- Cron / Auto backup ----
write_cron() {
  local full_spec="$1"   # e.g. "30 2 * * *"
  local data_spec="$2"   # e.g. "*/30 * * * *"
  local script_path="$3"
  local workdir="$4"

  [[ "$script_path" = /* ]] || die "script_path 必须是绝对路径"

  cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# RelayX backups (auto-generated)
${full_spec} root RELAYX_DIR=${workdir} ${script_path} full-backup >/var/log/relayx_full_backup.log 2>&1
${data_spec} root RELAYX_DIR=${workdir} ${script_path} data-backup >/var/log/relayx_data_backup.log 2>&1
EOF

  chmod 644 "$CRON_FILE"
}

delete_cron() {
  if [[ -f "$CRON_FILE" ]]; then
    rm -f "$CRON_FILE"
    info "已删除定时任务：$CRON_FILE\n"
  else
    info "没有发现定时任务：$CRON_FILE\n"
  fi
}

show_cron() {
  if [[ -f "$CRON_FILE" ]]; then
    info "\n当前定时任务（$CRON_FILE）："
    sed -n '1,200p' "$CRON_FILE"
    echo
  else
    info "\n当前没有 relayx 定时任务（$CRON_FILE 不存在）\n"
  fi
}

setup_auto_backup_menu() {
  local workdir="$1"
  local self_path="$2"

  info "\n== 自动备份设置 =="
  info "将写入：$CRON_FILE （覆盖更新）"
  info "日志：/var/log/relayx_full_backup.log  /var/log/relayx_data_backup.log\n"

  info "【整站备份】建议每天一次（在线，不暂停）。"
  read -r -p "请输入每天整站备份时间 (HH:MM)，例如 02:30 ：" full_time
  if [[ ! "$full_time" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    die "时间格式不对，应为 HH:MM（如 02:30）"
  fi
  local full_h="${full_time%:*}"
  local full_m="${full_time#*:}"
  full_h="$(echo "$full_h" | sed 's/^0\+//')"; [[ -z "$full_h" ]] && full_h="0"
  full_m="$(echo "$full_m" | sed 's/^0\+//')"; [[ -z "$full_m" ]] && full_m="0"
  local full_spec="${full_m} ${full_h} * * *"

  info "\n【数据备份】建议每 N 分钟一次（在线，不暂停）。"
  read -r -p "请输入间隔分钟数 N（例如 30 表示每 30 分钟）： " n
  n="$(normalize_choice "$n")"
  [[ "$n" =~ ^[0-9]+$ ]] || die "N 必须是数字"
  (( n >= 1 && n <= 1440 )) || die "N 建议 1~1440 分钟之间"
  local data_spec="*/${n} * * * *"

  write_cron "$full_spec" "$data_spec" "$self_path" "$workdir"
  info "\n✅ 定时任务已设置。\n"
  show_cron
  info "注意：cron 通常自动生效；如你的系统没启 cron，需要启动 cron 服务。\n"
}

# ---- Menu ----
print_header() {
  local workdir="$1"
  info "======================================"
  info " RelayX 整站备份/恢复 菜单"
  info " 当前目录: $workdir"
  info " 整站包:   $workdir/$SITE_BUNDLE_NAME (覆盖式)"
  info " 数据包:   $workdir/$DATA_BUNDLE_NAME (覆盖式)"
  info "======================================"
}

main_menu() {
  require_cmd docker
  require_cmd tar
  require_cmd gzip

  local workdir
  workdir="$(find_relayx_dir)"
  cd "$workdir"

  local self_path
  self_path="$(readlink -f "${BASH_SOURCE[0]}")"

  while true; do
    print_header "$workdir"
    echo "01) 整站备份"
    echo "02) 整站恢复"
    echo "03) 数据备份"
    echo "04) 恢复（先数据再整站）"
    echo "05) 查看状态"
    echo "06) 自动备份设置"
    echo "07) 查看自动备份"
    echo "08) 删除自动备份"
    echo "09) 退出"
    echo

    read -r -p "请选择 [01-09]: " choice_raw
    local choice
    choice="$(normalize_choice "$choice_raw")"

    case "$choice" in
      1) backup_full_online "$workdir" ;;
      2) restore_full_from_site_bundle "$workdir" ;;
      3) backup_data_online "$workdir" ;;
      4) restore_data_default_then_optional_full "$workdir" ;;
      5) show_status "$workdir" ;;
      6) setup_auto_backup_menu "$workdir" "$self_path" ;;
      7) show_cron ;;
      8) delete_cron ;;
      9) echo "Bye."; exit 0 ;;
      *) echo "无效选择：$choice_raw" ;;
    esac
  done
}

# ---- Non-interactive modes (for cron) ----
main_noninteractive() {
  require_cmd docker
  require_cmd tar
  require_cmd gzip

  local mode="${1:-}"
  local workdir
  workdir="$(find_relayx_dir)"
  cd "$workdir"

  case "$mode" in
    full-backup) backup_full_online "$workdir" ;;
    data-backup) backup_data_online "$workdir" ;;
    *) die "未知模式：$mode（可用：full-backup | data-backup）" ;;
  esac
}

# Entry
if [[ $# -ge 1 ]]; then
  main_noninteractive "$1"
else
  main_menu
fi
