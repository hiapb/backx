#!/usr/bin/env bash
set -euo pipefail

# ====== 可按需修改的配置 ======
WORKDIR="$(pwd)"
LOCAL_BACKUP_DIR="${WORKDIR}/backup_latest"          # 本地备份目录（覆盖）
SITE_BUNDLE="${WORKDIR}/site_backup_latest.tar.gz"   # 整站打包文件（覆盖）

# 你的卷名（来自 compose.yaml 里的 name:）
MYSQL_VOL="relayx-mysql"
REDIS_VOL="relayx-redis"
CADDY_DATA_VOL="relayx-caddy-data"
CADDY_CONFIG_VOL="relayx-caddy-config"

# 站点关键文件（在 compose.yaml 同级目录）
SITE_FILES=("compose.yaml" ".env" "Caddyfile")
# =============================

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }; }

check_prereq() {
  require_cmd docker
  require_cmd tar
}

ensure_site_files_exist() {
  local missing=0
  for f in "${SITE_FILES[@]}"; do
    if [[ ! -f "${WORKDIR}/${f}" ]]; then
      echo "缺少文件：${WORKDIR}/${f}"
      missing=1
    fi
  done
  if [[ $missing -eq 1 ]]; then
    echo
    echo "请确认 compose.yaml / .env / Caddyfile 都在当前目录。"
    exit 1
  fi
}

print_header() {
  echo "======================================"
  echo " RelayX 整站备份/恢复 菜单"
  echo " 当前目录: $WORKDIR"
  echo " 本地备份: $LOCAL_BACKUP_DIR"
  echo " 整站包:   $SITE_BUNDLE"
  echo "======================================"
}

show_status() {
  echo
  echo "Docker Compose 状态："
  docker compose ps || true
  echo
  echo "Docker Volumes："
  docker volume ls | grep -E "($MYSQL_VOL|$REDIS_VOL|$CADDY_DATA_VOL|$CADDY_CONFIG_VOL)" || true
  echo
  echo "本地备份目录："
  [[ -d "$LOCAL_BACKUP_DIR" ]] && ls -lah "$LOCAL_BACKUP_DIR" || echo "  (不存在)"
  echo
  echo "整站包文件："
  [[ -f "$SITE_BUNDLE" ]] && ls -lah "$SITE_BUNDLE" || echo "  (不存在)"
  echo
}

backup_volumes_to_dir() {
  rm -rf "$LOCAL_BACKUP_DIR"
  mkdir -p "$LOCAL_BACKUP_DIR/volumes"

  echo "[1/4] 备份 MySQL 卷 -> volumes/mysql.tar.gz"
  docker run --rm -v "${MYSQL_VOL}:/data:ro" -v "${LOCAL_BACKUP_DIR}/volumes:/backup" alpine \
    sh -c 'cd /data && tar -czf /backup/mysql.tar.gz .'

  echo "[2/4] 备份 Redis 卷 -> volumes/redis.tar.gz"
  docker run --rm -v "${REDIS_VOL}:/data:ro" -v "${LOCAL_BACKUP_DIR}/volumes:/backup" alpine \
    sh -c 'cd /data && tar -czf /backup/redis.tar.gz .'

  echo "[3/4] 备份 Caddy data -> volumes/caddy_data.tar.gz"
  docker run --rm -v "${CADDY_DATA_VOL}:/data:ro" -v "${LOCAL_BACKUP_DIR}/volumes:/backup" alpine \
    sh -c 'cd /data && tar -czf /backup/caddy_data.tar.gz .'

  echo "[4/4] 备份 Caddy config -> volumes/caddy_config.tar.gz"
  docker run --rm -v "${CADDY_CONFIG_VOL}:/data:ro" -v "${LOCAL_BACKUP_DIR}/volumes:/backup" alpine \
    sh -c 'cd /data && tar -czf /backup/caddy_config.tar.gz .'

  date +"backup_time=%F_%H%M%S" > "$LOCAL_BACKUP_DIR/manifest.txt"
  cat >> "$LOCAL_BACKUP_DIR/manifest.txt" <<EOF
mysql_volume=$MYSQL_VOL
redis_volume=$REDIS_VOL
caddy_data_volume=$CADDY_DATA_VOL
caddy_config_volume=$CADDY_CONFIG_VOL
EOF
}

backup_full_site_bundle() {
  echo
  echo "== 整站备份（覆盖旧备份/旧整站包）=="
  ensure_site_files_exist

  echo "为保证一致性，将执行：docker compose down"
  docker compose down

  backup_volumes_to_dir

  echo "[extra] 复制站点文件到本地备份目录..."
  mkdir -p "$LOCAL_BACKUP_DIR/site_files"
  for f in "${SITE_FILES[@]}"; do
    cp -f "${WORKDIR}/${f}" "$LOCAL_BACKUP_DIR/site_files/"
  done

  echo "[extra] 打包为整站包 -> $SITE_BUNDLE"
  rm -f "$SITE_BUNDLE"
  tar -czf "$SITE_BUNDLE" -C "$WORKDIR" "$(basename "$LOCAL_BACKUP_DIR")"

  echo "备份完成："
  echo " - 本地目录：$LOCAL_BACKUP_DIR"
  echo " - 整站包：  $SITE_BUNDLE"

  echo "重新启动服务：docker compose up -d"
  docker compose up -d
  echo "✅ 完成"
  echo
}

restore_from_full_site_bundle() {
  echo
  echo "== 从整站包恢复（可用于新机器/重装后）=="
  if [[ ! -f "$SITE_BUNDLE" ]]; then
    echo "找不到整站包：$SITE_BUNDLE"
    echo "请把 site_backup_latest.tar.gz 拷到当前目录后再试。"
    return
  fi

  read -r -p "确认恢复整站？会覆盖当前数据和文件。输入 YES 继续: " ans
  if [[ "$ans" != "YES" ]]; then
    echo "已取消。"
    return
  fi

  echo "[1/5] 停止服务..."
  docker compose down || true

  echo "[2/5] 解包整站到当前目录（会覆盖 backup_latest）..."
  rm -rf "$LOCAL_BACKUP_DIR"
  tar -xzf "$SITE_BUNDLE" -C "$WORKDIR"

  echo "[3/5] 恢复站点文件 compose.yaml/.env/Caddyfile（覆盖当前）..."
  if [[ -d "$LOCAL_BACKUP_DIR/site_files" ]]; then
    for f in "${SITE_FILES[@]}"; do
      if [[ -f "$LOCAL_BACKUP_DIR/site_files/$f" ]]; then
        cp -f "$LOCAL_BACKUP_DIR/site_files/$f" "$WORKDIR/$f"
      fi
    done
  else
    echo "警告：整站包内缺少 site_files，跳过文件恢复。"
  fi

  echo "[4/5] 恢复卷（删除旧卷 -> 重建 -> 解包）..."
  docker volume rm -f "$MYSQL_VOL" "$REDIS_VOL" "$CADDY_DATA_VOL" "$CADDY_CONFIG_VOL" >/dev/null 2>&1 || true
  docker volume create "$MYSQL_VOL" >/dev/null
  docker volume create "$REDIS_VOL" >/dev/null
  docker volume create "$CADDY_DATA_VOL" >/dev/null
  docker volume create "$CADDY_CONFIG_VOL" >/dev/null

  for f in mysql redis caddy_data caddy_config; do
    [[ -f "$LOCAL_BACKUP_DIR/volumes/${f}.tar.gz" ]] || { echo "缺少备份：$LOCAL_BACKUP_DIR/volumes/${f}.tar.gz"; exit 1; }
  done

  docker run --rm -v "${MYSQL_VOL}:/data" -v "${LOCAL_BACKUP_DIR}/volumes:/backup:ro" alpine \
    sh -c 'cd /data && tar -xzf /backup/mysql.tar.gz'
  docker run --rm -v "${REDIS_VOL}:/data" -v "${LOCAL_BACKUP_DIR}/volumes:/backup:ro" alpine \
    sh -c 'cd /data && tar -xzf /backup/redis.tar.gz'
  docker run --rm -v "${CADDY_DATA_VOL}:/data" -v "${LOCAL_BACKUP_DIR}/volumes:/backup:ro" alpine \
    sh -c 'cd /data && tar -xzf /backup/caddy_data.tar.gz'
  docker run --rm -v "${CADDY_CONFIG_VOL}:/data" -v "${LOCAL_BACKUP_DIR}/volumes:/backup:ro" alpine \
    sh -c 'cd /data && tar -xzf /backup/caddy_config.tar.gz'

  echo "[5/5] 启动服务..."
  docker compose up -d
  docker compose ps
  echo "✅ 整站恢复完成"
  echo
}

restore_local_volumes_only() {
  echo
  echo "== 用本机 backup_latest 恢复卷（不管整站包）=="
  if [[ ! -d "$LOCAL_BACKUP_DIR/volumes" ]]; then
    echo "找不到本地备份：$LOCAL_BACKUP_DIR/volumes"
    echo "请先做一次备份。"
    return
  fi

  read -r -p "确认恢复？会覆盖当前数据。输入 YES 继续: " ans
  if [[ "$ans" != "YES" ]]; then
    echo "已取消。"
    return
  fi

  docker compose down || true

  docker volume rm -f "$MYSQL_VOL" "$REDIS_VOL" "$CADDY_DATA_VOL" "$CADDY_CONFIG_VOL" >/dev/null 2>&1 || true
  docker volume create "$MYSQL_VOL" >/dev/null
  docker volume create "$REDIS_VOL" >/dev/null
  docker volume create "$CADDY_DATA_VOL" >/dev/null
  docker volume create "$CADDY_CONFIG_VOL" >/dev/null

  docker run --rm -v "${MYSQL_VOL}:/data" -v "${LOCAL_BACKUP_DIR}/volumes:/backup:ro" alpine \
    sh -c 'cd /data && tar -xzf /backup/mysql.tar.gz'
  docker run --rm -v "${REDIS_VOL}:/data" -v "${LOCAL_BACKUP_DIR}/volumes:/backup:ro" alpine \
    sh -c 'cd /data && tar -xzf /backup/redis.tar.gz'
  docker run --rm -v "${CADDY_DATA_VOL}:/data" -v "${LOCAL_BACKUP_DIR}/volumes:/backup:ro" alpine \
    sh -c 'cd /data && tar -xzf /backup/caddy_data.tar.gz'
  docker run --rm -v "${CADDY_CONFIG_VOL}:/data" -v "${LOCAL_BACKUP_DIR}/volumes:/backup:ro" alpine \
    sh -c 'cd /data && tar -xzf /backup/caddy_config.tar.gz'

  docker compose up -d
  docker compose ps
  echo "✅ 恢复完成"
  echo
}

main_menu() {
  check_prereq

  while true; do
    print_header
    echo "1) 整站备份"
    echo "2) 整站恢复"
    echo "3) 数据恢复"
    echo "4) 查看状态"
    echo "5) 退出"
    echo
    read -r -p "请选择 [1-5]: " choice

    case "$choice" in
      1) backup_full_site_bundle ;;
      2) restore_from_full_site_bundle ;;
      3) restore_local_volumes_only ;;
      4) show_status ;;
      5) echo "Bye."; exit 0 ;;
      *) echo "无效选择：$choice" ;;
    esac
  done
}

main_menu
