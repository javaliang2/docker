#!/bin/bash
# ================================================================
#  Docker + Docker Compose  安装 / 应用部署 / 升级 管理脚本
#
#  用法:
#    sudo bash setup-docker-apps.sh            # 交互式菜单
#    sudo bash setup-docker-apps.sh deploy all # 部署全部应用
#    sudo bash setup-docker-apps.sh deploy wordpress
#    sudo bash setup-docker-apps.sh upgrade all
#    sudo bash setup-docker-apps.sh upgrade wordpress
#    sudo bash setup-docker-apps.sh clone wordpress wordpress2 8084
#    sudo bash setup-docker-apps.sh status     # 查看所有容器状态
#
#  新增应用只需：
#    1. 在 APP_LIST 数组中加一行  "key|名称|端口"
#    2. 实现对应的  deploy_<key>()  函数
#  ——其他所有菜单、升级、状态逻辑自动生效
# ================================================================
set -euo pipefail

# ── 颜色 ─────────────────────────────────────────────────────────
RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

log()    { echo -e "${GREEN}[✔]${NC} $*"; }
warn()   { echo -e "${YELLOW}[!]${NC} $*"; }
error()  { echo -e "${RED}[✘]${NC} $*"; exit 1; }
info()   { echo -e "${BLUE}[i]${NC} $*"; }
header() { echo -e "\n${CYAN}${BOLD}━━━  $*  ━━━${NC}\n"; }
hr()     { echo -e "${DIM}────────────────────────────────────────────────${NC}"; }

# ── 基础目录 ──────────────────────────────────────────────────────
BASE_DIR="/opt/docker-apps"
mkdir -p "$BASE_DIR"

[[ $EUID -ne 0 ]] && error "请使用 root 或 sudo 运行此脚本"

# ================================================================
# ★  应用注册表
#    格式:  "key|显示名称|本地访问端口|简介"
#    新增应用: 在这里加一行 + 实现 deploy_<key>() 函数即可
# ================================================================
declare -a APP_LIST=(
  "wordpress   | WordPress          | 8080 | 博客/CMS，含 MariaDB + Redis"
  "nextcloud   | Nextcloud          | 8081 | 私有云盘，含 MariaDB + Redis"
  "gitea       | Gitea              | 3000 | 轻量 Git 服务，含 PostgreSQL"
  "alist       | AList              | 5244 | 多存储聚合网盘"
  "uptime_kuma | Uptime Kuma        | 3001 | 服务监控面板"
  "portainer   | Portainer CE       | 9000 | Docker 可视化管理"
  "phpmyadmin  | phpMyAdmin         | 8082 | MySQL/MariaDB Web 管理"
  "redis_cmd   | Redis Commander    | 8083 | Redis Web GUI"
)

# 解析注册表 helper
app_key()  { echo "$1" | awk -F'|' '{gsub(/ /,"",$1); print $1}'; }
app_name() { echo "$1" | awk -F'|' '{gsub(/^ +| +$/,"",$2); print $2}'; }
app_port() { echo "$1" | awk -F'|' '{gsub(/ /,"",$3); print $3}'; }
app_desc() { echo "$1" | awk -F'|' '{gsub(/^ +| +$/,"",$4); print $4}'; }

# ================================================================
# 工具函数
# ================================================================
randpw() { tr -dc 'A-Za-z0-9@#%^&*' </dev/urandom | head -c "${1:-20}"; }

# 跳过已部署的应用（docker-compose.yml 存在则视为已部署）
already_deployed() {
  local key=$1
  [[ -f "$BASE_DIR/$key/docker-compose.yml" ]]
}

# ================================================================
# 1. 安装 / 更新 Docker
# ================================================================
install_docker() {
  header "安装 / 更新 Docker Engine"

  if command -v docker &>/dev/null; then
    CURRENT=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
    warn "已检测到 Docker $CURRENT，执行更新..."
  fi

  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg" \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
    $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker

  log "Docker        $(docker version --format '{{.Server.Version}}')"
  log "Compose       $(docker compose version --short)"
}

# ================================================================
# 2. 升级单个应用（pull 最新镜像 → 重建容器）
# ================================================================
upgrade_app() {
  local key=$1
  local DIR="$BASE_DIR/$key"

  if ! already_deployed "$key"; then
    warn "[$key] 尚未部署，跳过升级"
    return
  fi

  header "升级 $key"
  (
    cd "$DIR"
    docker compose pull          # 拉取所有服务最新镜像
    docker compose up -d --remove-orphans   # 重建有变更的容器
    docker image prune -f        # 清理旧镜像
  )
  log "$key 升级完成"
}

# 升级全部已部署的应用
upgrade_all() {
  header "升级所有已部署应用"
  for entry in "${APP_LIST[@]}"; do
    local key; key=$(app_key "$entry")
    upgrade_app "$key"
  done
  log "全部升级完成"
}

# ================================================================
# 3. 状态总览
# ================================================================
show_status() {
  header "应用运行状态"
  printf "%-16s %-20s %-8s %s\n" "KEY" "NAME" "PORT" "STATUS"
  hr
  for entry in "${APP_LIST[@]}"; do
    local key name port status
    key=$(app_key "$entry"); name=$(app_name "$entry"); port=$(app_port "$entry")
    if already_deployed "$key"; then
      # 检查是否有容器在跑
      running=$(docker compose -f "$BASE_DIR/$key/docker-compose.yml" ps --status running -q 2>/dev/null | wc -l)
      if [[ $running -gt 0 ]]; then
        status="${GREEN}running($running)${NC}"
      else
        status="${YELLOW}stopped${NC}"
      fi
    else
      status="${DIM}not deployed${NC}"
    fi
    printf "%-16s %-20s %-8s " "$key" "$name" ":$port"
    echo -e "$status"
  done
  hr
}

# ================================================================
# ── 以下每个 deploy_* 函数对应一个应用 ──
# ================================================================

# ── WordPress（MariaDB + Redis + nginx-fpm sidecar）─────────────
deploy_wordpress() {
  local DIR="$BASE_DIR/wordpress"
  mkdir -p "$DIR"/{data,db,redis,conf}

  local DB_ROOT_PW; DB_ROOT_PW=$(randpw 24)
  local DB_PW;      DB_PW=$(randpw 24)

  cat > "$DIR/.env" <<EOF
WORDPRESS_DB_ROOT_PASSWORD=$DB_ROOT_PW
WORDPRESS_DB_PASSWORD=$DB_PW
WORDPRESS_DB_NAME=wordpress
WORDPRESS_DB_USER=wpuser
EOF

  cat > "$DIR/docker-compose.yml" <<'YAML'
version: "3.9"
services:
  db:
    image: mariadb:11
    restart: unless-stopped
    env_file: .env
    environment:
      MARIADB_ROOT_PASSWORD: ${WORDPRESS_DB_ROOT_PASSWORD}
      MARIADB_DATABASE: ${WORDPRESS_DB_NAME}
      MARIADB_USER: ${WORDPRESS_DB_USER}
      MARIADB_PASSWORD: ${WORDPRESS_DB_PASSWORD}
    volumes:
      - ./db:/var/lib/mysql
    networks: [wp_net]
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    command: redis-server --save 60 1 --loglevel warning
    volumes:
      - ./redis:/data
    networks: [wp_net]

  wordpress:
    image: wordpress:php8.3-fpm-alpine
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    env_file: .env
    environment:
      WORDPRESS_DB_HOST: db:3306
      WORDPRESS_DB_NAME: ${WORDPRESS_DB_NAME}
      WORDPRESS_DB_USER: ${WORDPRESS_DB_USER}
      WORDPRESS_DB_PASSWORD: ${WORDPRESS_DB_PASSWORD}
      WORDPRESS_CONFIG_EXTRA: |
        define('WP_REDIS_HOST', 'redis');
        define('WP_REDIS_PORT', 6379);
        define('WP_CACHE', true);
        define('WP_MEMORY_LIMIT', '512M');
        define('WP_MAX_MEMORY_LIMIT', '1024M');
    volumes:
      - ./data:/var/www/html
      - ./conf/php-uploads.ini:/usr/local/etc/php/conf.d/uploads.ini:ro
    networks: [wp_net]

  nginx:
    image: nginx:alpine
    restart: unless-stopped
    depends_on: [wordpress]
    volumes:
      - ./data:/var/www/html:ro
      - ./conf/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    networks: [wp_net]
    ports:
      - "127.0.0.1:8080:80"

networks:
  wp_net:
    driver: bridge
YAML

  cat > "$DIR/conf/php-uploads.ini" <<'INI'
upload_max_filesize = 2048M
post_max_size       = 2048M
memory_limit        = 1024M
max_execution_time  = 600
max_input_time      = 600
max_input_vars      = 10000
INI

  cat > "$DIR/conf/nginx.conf" <<'NGINX'
server {
    listen 80;
    root /var/www/html;
    index index.php index.html;
    client_max_body_size 2048M;
    location / { try_files $uri $uri/ /index.php?$args; }
    location ~ \.php$ {
        fastcgi_pass  wordpress:9000;
        fastcgi_index index.php;
        include       fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_read_timeout 600;
    }
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2)$ {
        expires max; log_not_found off;
    }
}
NGINX

  ( cd "$DIR" && docker compose up -d )
  log "WordPress → http://127.0.0.1:8080   凭据: $DIR/.env"
}

# ── Nextcloud（MariaDB + Redis + cron + nginx-fpm sidecar）──────
deploy_nextcloud() {
  local DIR="$BASE_DIR/nextcloud"
  mkdir -p "$DIR"/{data,db,config,apps,conf}

  local DB_ROOT_PW; DB_ROOT_PW=$(randpw 24)
  local DB_PW;      DB_PW=$(randpw 24)
  local ADMIN_PW;   ADMIN_PW=$(randpw 20)

  cat > "$DIR/.env" <<EOF
MYSQL_ROOT_PASSWORD=$DB_ROOT_PW
MYSQL_PASSWORD=$DB_PW
NEXTCLOUD_ADMIN_PASSWORD=$ADMIN_PW
EOF

  cat > "$DIR/docker-compose.yml" <<'YAML'
version: "3.9"
services:
  db:
    image: mariadb:11
    restart: unless-stopped
    env_file: .env
    environment:
      MARIADB_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MARIADB_DATABASE: nextcloud
      MARIADB_USER: nextcloud
      MARIADB_PASSWORD: ${MYSQL_PASSWORD}
    volumes:
      - ./db:/var/lib/mysql
    networks: [nc_net]
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    networks: [nc_net]

  nextcloud:
    image: nextcloud:production-fpm-alpine
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    env_file: .env
    environment:
      MYSQL_HOST: db
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
      REDIS_HOST: redis
      NEXTCLOUD_ADMIN_USER: admin
      NEXTCLOUD_ADMIN_PASSWORD: ${NEXTCLOUD_ADMIN_PASSWORD}
      PHP_UPLOAD_LIMIT: 2048M
      PHP_MEMORY_LIMIT: 1024M
    volumes:
      - ./data:/var/www/html/data
      - ./config:/var/www/html/config
      - ./apps:/var/www/html/custom_apps
    networks: [nc_net]

  nginx:
    image: nginx:alpine
    restart: unless-stopped
    depends_on: [nextcloud]
    volumes:
      - ./data:/var/www/html/data:ro
      - ./config:/var/www/html/config:ro
      - ./conf/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    networks: [nc_net]
    ports:
      - "127.0.0.1:8081:80"

  cron:
    image: nextcloud:production-fpm-alpine
    restart: unless-stopped
    depends_on: [nextcloud]
    entrypoint: /cron.sh
    volumes:
      - ./data:/var/www/html/data
      - ./config:/var/www/html/config
    networks: [nc_net]

networks:
  nc_net:
    driver: bridge
YAML

  cat > "$DIR/conf/nginx.conf" <<'NGINX'
upstream php-handler { server nextcloud:9000; }
server {
    listen 80;
    root /var/www/html;
    client_max_body_size 2048M;
    location = /robots.txt { allow all; log_not_found off; access_log off; }
    location ^~ /.well-known { return 301 /index.php$uri; }
    location / { rewrite ^ /index.php; }
    location ~ ^\/(?:build|tests|config|lib|3rdparty|templates|data)\/ { deny all; }
    location ~ ^\/(?:index|remote|public|cron|core\/ajax\/update|status|ocs\/v[12]|updater\/.+|oc[ms]-provider\/.+)\.php(?:$|\/) {
        fastcgi_split_path_info ^(.+?\.php)(\/.*|)$;
        fastcgi_pass php-handler;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $fastcgi_path_info;
        fastcgi_read_timeout 600;
    }
    location ~* \.(?:css|js|woff2|svg|gif|map)$ { try_files $uri /index.php$request_uri; expires 6M; }
    location ~* \.(?:png|html|ttf|ico|jpg|jpeg)$ { try_files $uri /index.php$request_uri; }
}
NGINX

  ( cd "$DIR" && docker compose up -d )
  log "Nextcloud → http://127.0.0.1:8081   admin / $(grep NEXTCLOUD_ADMIN_PASSWORD "$DIR/.env" | cut -d= -f2)"
}

# ── Gitea（PostgreSQL）──────────────────────────────────────────
deploy_gitea() {
  local DIR="$BASE_DIR/gitea"
  mkdir -p "$DIR"/{data,db}

  local DB_PW; DB_PW=$(randpw 24)
  cat > "$DIR/.env" <<EOF
POSTGRES_PASSWORD=$DB_PW
EOF

  cat > "$DIR/docker-compose.yml" <<'YAML'
version: "3.9"
services:
  db:
    image: postgres:16-alpine
    restart: unless-stopped
    env_file: .env
    environment:
      POSTGRES_USER: gitea
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: gitea
    volumes:
      - ./db:/var/lib/postgresql/data
    networks: [gitea_net]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U gitea"]
      interval: 10s
      timeout: 5s
      retries: 5

  gitea:
    image: gitea/gitea:latest
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    env_file: .env
    environment:
      USER_UID: 1000
      USER_GID: 1000
      GITEA__database__DB_TYPE: postgres
      GITEA__database__HOST: db:5432
      GITEA__database__NAME: gitea
      GITEA__database__USER: gitea
      GITEA__database__PASSWD: ${POSTGRES_PASSWORD}
      GITEA__server__DOMAIN: localhost
      GITEA__server__ROOT_URL: http://localhost/
      GITEA__attachment__MAX_SIZE: 2048
    volumes:
      - ./data:/data
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    ports:
      - "127.0.0.1:3000:3000"
      - "127.0.0.1:2222:22"
    networks: [gitea_net]

networks:
  gitea_net:
    driver: bridge
YAML

  ( cd "$DIR" && docker compose up -d )
  log "Gitea → http://127.0.0.1:3000   SSH: :2222   凭据: $DIR/.env"
}

# ── AList（多存储聚合网盘）──────────────────────────────────────
# AList 支持：本地、阿里云盘、OneDrive、Google Drive、S3、WebDAV 等
deploy_alist() {
  local DIR="$BASE_DIR/alist"
  mkdir -p "$DIR/data"

  cat > "$DIR/docker-compose.yml" <<'YAML'
version: "3.9"
services:
  alist:
    image: xhofe/alist:latest
    restart: unless-stopped
    volumes:
      - ./data:/opt/alist/data
    ports:
      - "127.0.0.1:5244:5244"
    environment:
      PUID: 0
      PGID: 0
      UMASK: 022
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:5244/api/auth/login"]
      interval: 30s
      timeout: 10s
      retries: 3
YAML

  ( cd "$DIR" && docker compose up -d )

  # 等待容器就绪后读取初始密码
  info "等待 AList 初始化（约 5 秒）..."
  sleep 5
  ALIST_PW=$(docker compose -f "$DIR/docker-compose.yml" exec -T alist \
    ./alist admin random 2>/dev/null | grep -oP '(?<=password: )\S+' || echo "请运行: docker exec alist ./alist admin random")

  cat > "$DIR/.env" <<EOF
# AList 管理密码（首次生成）
ALIST_ADMIN_PASSWORD=$ALIST_PW
# 如需重置: docker compose exec alist ./alist admin random
# 如需设置固定密码: docker compose exec alist ./alist admin set <密码>
EOF

  log "AList → http://127.0.0.1:5244   admin / $ALIST_PW"
  log "凭据已保存至 $DIR/.env"
}

# ── Uptime Kuma ─────────────────────────────────────────────────
deploy_uptime_kuma() {
  local DIR="$BASE_DIR/uptime_kuma"
  mkdir -p "$DIR/data"

  cat > "$DIR/docker-compose.yml" <<'YAML'
version: "3.9"
services:
  uptime-kuma:
    image: louislam/uptime-kuma:latest
    restart: unless-stopped
    volumes:
      - ./data:/app/data
    ports:
      - "127.0.0.1:3001:3001"
YAML

  ( cd "$DIR" && docker compose up -d )
  log "Uptime Kuma → http://127.0.0.1:3001"
}

# ── Portainer CE ────────────────────────────────────────────────
deploy_portainer() {
  local DIR="$BASE_DIR/portainer"
  mkdir -p "$DIR/data"

  cat > "$DIR/docker-compose.yml" <<'YAML'
version: "3.9"
services:
  portainer:
    image: portainer/portainer-ce:latest
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/data
    ports:
      - "127.0.0.1:9000:9000"
      - "127.0.0.1:9443:9443"
YAML

  ( cd "$DIR" && docker compose up -d )
  log "Portainer → http://127.0.0.1:9000   HTTPS: https://127.0.0.1:9443"
}

# ── phpMyAdmin ──────────────────────────────────────────────────
deploy_phpmyadmin() {
  local DIR="$BASE_DIR/phpmyadmin"
  mkdir -p "$DIR"

  cat > "$DIR/docker-compose.yml" <<'YAML'
version: "3.9"
services:
  phpmyadmin:
    image: phpmyadmin:latest
    restart: unless-stopped
    environment:
      PMA_ARBITRARY: 1
      UPLOAD_LIMIT: 2048M
      MEMORY_LIMIT: 1024M
      MAX_EXECUTION_TIME: 600
    ports:
      - "127.0.0.1:8082:80"
YAML

  ( cd "$DIR" && docker compose up -d )
  log "phpMyAdmin → http://127.0.0.1:8082   （可连接任意 MySQL/MariaDB 主机）"
}

# ── Redis Commander ─────────────────────────────────────────────
deploy_redis_cmd() {
  local DIR="$BASE_DIR/redis_cmd"
  mkdir -p "$DIR"

  cat > "$DIR/docker-compose.yml" <<'YAML'
version: "3.9"
services:
  redis-commander:
    image: rediscommander/redis-commander:latest
    restart: unless-stopped
    environment:
      REDIS_HOSTS: "local:host.docker.internal:6379"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    ports:
      - "127.0.0.1:8083:8081"
YAML

  ( cd "$DIR" && docker compose up -d )
  log "Redis Commander → http://127.0.0.1:8083"
}

# ================================================================
# 调度：根据 key 调用对应 deploy_* 函数
# ================================================================
do_deploy() {
  local key=$1

  if already_deployed "$key"; then
    warn "[$key] 已存在部署目录，跳过（如需重新部署请先删除 $BASE_DIR/$key）"
    return
  fi

  # 动态调用 deploy_<key>
  if declare -f "deploy_$key" > /dev/null; then
    header "部署 $key"
    "deploy_$key"
  else
    error "未找到 deploy_${key}() 函数，请检查脚本"
  fi
}

# ================================================================
# 汇总打印
# ================================================================
print_summary() {
  echo ""
  echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗"
  echo -e "║           🐳  部署完成 — 端口 & 凭据汇总                    ║"
  echo -e "╠══════════════════════════════════════════════════════════════╣"
  for entry in "${APP_LIST[@]}"; do
    local key name port
    key=$(app_key "$entry"); name=$(app_name "$entry"); port=$(app_port "$entry")
    if already_deployed "$key"; then
      printf "║  %-18s → http://127.0.0.1:%-6s                  ║\n" "$name" "$port"
    fi
  done
  echo -e "╠══════════════════════════════════════════════════════════════╣"
  echo -e "║  凭据文件: /opt/docker-apps/<app>/.env                      ║"
  echo -e "║  升级全部: sudo bash $0 upgrade all          ║"
  echo -e "║  升级单个: sudo bash $0 upgrade <key>        ║"
  echo -e "╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

# ================================================================
# clone_app  —  从已部署的应用复制出一个新实例
#   $1  源 key（如 wordpress）
#   $2  新 key（如 wordpress2）
#   $3  新端口（如 8084）
# ================================================================
clone_app() {
  local SRC_KEY="${1:-}"
  local DST_KEY="${2:-}"
  local NEW_PORT="${3:-}"

  # ── 参数校验 ──────────────────────────────────────────────────
  [[ -z "$SRC_KEY" || -z "$DST_KEY" || -z "$NEW_PORT" ]] && \
    error "用法: $0 clone <源key> <新key> <新端口>\n       例如: $0 clone wordpress wordpress2 8084"

  local SRC_DIR="$BASE_DIR/$SRC_KEY"
  local DST_DIR="$BASE_DIR/$DST_KEY"

  already_deployed "$SRC_KEY" || error "源应用 [$SRC_KEY] 尚未部署，请先部署后再克隆"
  [[ -d "$DST_DIR" ]] && error "目标目录 $DST_DIR 已存在，请换一个新 key 或手动删除"

  # 检查端口是否已被占用（ss 或 netstat）
  if ss -tlnp 2>/dev/null | grep -q ":${NEW_PORT} " || \
     grep -r "127.0.0.1:${NEW_PORT}:" "$BASE_DIR"/*/docker-compose.yml 2>/dev/null | grep -q .; then
    error "端口 $NEW_PORT 已被占用，请换一个端口"
  fi

  header "克隆 $SRC_KEY → $DST_KEY (端口 $NEW_PORT)"

  # ── 复制目录（排除运行时数据，只复制配置）──────────────────
  info "复制配置文件..."
  cp -r "$SRC_DIR" "$DST_DIR"

  # 删掉源实例的运行时数据（数据库、应用数据），新实例应全新初始化
  # 保留: docker-compose.yml / conf/ / nginx.conf 等配置文件
  for runtime_dir in db data redis config apps; do
    [[ -d "$DST_DIR/$runtime_dir" ]] && rm -rf "${DST_DIR:?}/$runtime_dir" && mkdir -p "$DST_DIR/$runtime_dir"
  done

  # ── 替换端口 ──────────────────────────────────────────────────
  # 找出源目录 compose 里绑定的宿主机端口（取第一个 127.0.0.1:XXXX）
  local OLD_PORT
  OLD_PORT=$(grep -oP '127\.0\.0\.1:\K[0-9]+(?=:)' "$DST_DIR/docker-compose.yml" | head -1)

  if [[ -n "$OLD_PORT" ]]; then
    sed -i "s/127\.0\.0\.1:${OLD_PORT}:/127.0.0.1:${NEW_PORT}:/g" "$DST_DIR/docker-compose.yml"
    info "端口: $OLD_PORT → $NEW_PORT"
  else
    warn "未能自动替换端口，请手动检查 $DST_DIR/docker-compose.yml"
  fi

  # ── 替换 Docker 网络名（避免与源实例冲突）──────────────────
  # 将所有形如 xxx_net 的网络名加上 _<DST_KEY> 后缀
  sed -i -E "s/([a-z]+_net)\b/\1_${DST_KEY}/g" "$DST_DIR/docker-compose.yml"
  info "网络名已隔离（加后缀 _${DST_KEY}）"

  # ── 重新生成 .env 密码（避免两个实例共用相同密码）─────────
  if [[ -f "$DST_DIR/.env" ]]; then
    info "重新生成 .env 密码..."
    local tmp_env="$DST_DIR/.env.new"
    # 对所有含 PASSWORD / SECRET / TOKEN 的行重新生成随机值
    while IFS= read -r line; do
      if echo "$line" | grep -qiE '(PASSWORD|SECRET|TOKEN)=.+'; then
        local key_name val_prefix
        key_name=$(echo "$line" | cut -d= -f1)
        echo "${key_name}=$(randpw 24)"
      else
        echo "$line"
      fi
    done < "$DST_DIR/.env" > "$tmp_env"
    mv "$tmp_env" "$DST_DIR/.env"
    info "新凭据已保存至 $DST_DIR/.env"
  fi

  # ── 启动新实例 ────────────────────────────────────────────────
  ( cd "$DST_DIR" && docker compose up -d )

  echo ""
  log "克隆完成！"
  log "新实例目录: $DST_DIR"
  log "访问地址:   http://127.0.0.1:$NEW_PORT"
  log "凭据文件:   $DST_DIR/.env"
  info "提示：此实例数据库全新初始化，与源实例 [$SRC_KEY] 数据完全隔离"
}

# ================================================================
# 交互式菜单
# ================================================================
interactive_menu() {
  while true; do
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗"
    echo -e "║                🐳  Docker 应用管理脚本                      ║"
    echo -e "╠══════════════════════════════════════════════════════════════╣"
    echo -e "║  1) 安装 / 更新 Docker + Compose                            ║"
    echo -e "║  2) 部署应用（选择）                                        ║"
    echo -e "║  3) 部署全部应用                                            ║"
    echo -e "║  4) 升级应用（选择）                                        ║"
    echo -e "║  5) 升级全部已部署应用                                      ║"
    echo -e "║  6) 查看运行状态                                            ║"
    echo -e "║  7) 克隆应用（同一应用部署多实例）                          ║"
    echo -e "║  0) 退出                                                    ║"
    echo -e "╚══════════════════════════════════════════════════════════════╝${NC}"
    echo -n "  请选择 [0-7]: "
    read -r choice

    case $choice in
      1) install_docker ;;

      2)
        echo ""
        echo -e "${BOLD}可用应用列表：${NC}"
        local i=1
        for entry in "${APP_LIST[@]}"; do
          local key name port desc deployed_flag=""
          key=$(app_key "$entry"); name=$(app_name "$entry")
          port=$(app_port "$entry"); desc=$(app_desc "$entry")
          already_deployed "$key" && deployed_flag="${GREEN}[已部署]${NC}" || deployed_flag="${DIM}[未部署]${NC}"
          printf "  %2d) %-18s :%-6s  %s  %b\n" $i "$name" "$port" "$desc" "$deployed_flag"
          ((i++))
        done
        echo -n "  请输入编号（多个用空格分隔，如 1 3 5）: "
        read -r -a selections
        for sel in "${selections[@]}"; do
          if [[ $sel =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#APP_LIST[@]} )); then
            local entry="${APP_LIST[$((sel-1))]}"
            do_deploy "$(app_key "$entry")"
          else
            warn "无效编号: $sel"
          fi
        done
        print_summary
        ;;

      3)
        for entry in "${APP_LIST[@]}"; do
          do_deploy "$(app_key "$entry")"
        done
        print_summary
        ;;

      4)
        echo ""
        echo -e "${BOLD}已部署应用：${NC}"
        local i=1
        declare -a deployed_keys=()
        for entry in "${APP_LIST[@]}"; do
          local key name port
          key=$(app_key "$entry"); name=$(app_name "$entry"); port=$(app_port "$entry")
          if already_deployed "$key"; then
            printf "  %2d) %-18s :%-6s\n" $i "$name" "$port"
            deployed_keys+=("$key")
            ((i++))
          fi
        done
        if [[ ${#deployed_keys[@]} -eq 0 ]]; then
          warn "暂无已部署的应用"
        else
          echo -n "  请输入编号（多个用空格分隔）: "
          read -r -a selections
          for sel in "${selections[@]}"; do
            if [[ $sel =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#deployed_keys[@]} )); then
              upgrade_app "${deployed_keys[$((sel-1))]}"
            else
              warn "无效编号: $sel"
            fi
          done
        fi
        ;;

      5) upgrade_all ;;

      6) show_status ;;

      7)
        echo ""
        echo -e "${BOLD}已部署应用（可作为克隆源）：${NC}"
        local i=1
        declare -a deployed_keys=()
        for entry in "${APP_LIST[@]}"; do
          local key name port
          key=$(app_key "$entry"); name=$(app_name "$entry"); port=$(app_port "$entry")
          if already_deployed "$key"; then
            printf "  %2d) %-18s :%-6s\n" $i "$name" "$port"
            deployed_keys+=("$key")
            ((i++))
          fi
        done
        if [[ ${#deployed_keys[@]} -eq 0 ]]; then
          warn "暂无已部署的应用"
        else
          echo -n "  选择源应用编号: "
          read -r sel
          if [[ $sel =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#deployed_keys[@]} )); then
            local src_key="${deployed_keys[$((sel-1))]}"
            echo -n "  新实例名称（如 ${src_key}2）: "
            read -r dst_key
            echo -n "  新实例端口（如 8090）: "
            read -r new_port
            clone_app "$src_key" "$dst_key" "$new_port"
          else
            warn "无效编号"
          fi
        fi
        ;;

      0) echo "退出"; exit 0 ;;

      *) warn "无效选项，请重新输入" ;;
    esac
  done
}

# ================================================================
# 命令行入口
# ================================================================
CMD="${1:-menu}"
case "$CMD" in
  deploy)
    KEY="${2:-}"
    [[ -z "$KEY" ]] && error "用法: $0 deploy <key|all>"
    if [[ "$KEY" == "all" ]]; then
      install_docker
      for entry in "${APP_LIST[@]}"; do do_deploy "$(app_key "$entry")"; done
      print_summary
    else
      do_deploy "$KEY"
    fi
    ;;
  upgrade)
    KEY="${2:-}"
    [[ -z "$KEY" ]] && error "用法: $0 upgrade <key|all>"
    [[ "$KEY" == "all" ]] && upgrade_all || upgrade_app "$KEY"
    ;;
  status)
    show_status
    ;;
  clone)
    clone_app "${2:-}" "${3:-}" "${4:-}"
    ;;
  menu|*)
    interactive_menu
    ;;
esac
