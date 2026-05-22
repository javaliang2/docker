#!/bin/bash
# ============================================================
#  Docker + Docker Compose 安装 & 热门应用一键部署脚本
#  支持：WordPress / Nextcloud / Gitea / Uptime Kuma /
#        Portainer / phpMyAdmin / Redis Commander / MinIO /
#        Lsky Pro / EasyImage / Nginx Proxy Manager /
#        Vaultwarden / N8N
#  用法：sudo bash setup-docker-apps.sh [选项]
# ============================================================

set -euo pipefail

# ── 颜色 ────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()    { echo -e "${GREEN}[✔]${NC} $*"; }
warn()   { echo -e "${YELLOW}[!]${NC} $*"; }
error()  { echo -e "${RED}[✘]${NC} $*"; exit 1; }
header() { echo -e "\n${CYAN}${BOLD}━━━ $* ━━━${NC}\n"; }

# ── 基础目录 ─────────────────────────────────────────────────
BASE_DIR="/opt/docker-apps"
mkdir -p "$BASE_DIR"

# ── 检查 root ────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "请使用 root 或 sudo 运行此脚本"

# ── 显示帮助 ─────────────────────────────────────────────────
usage() {
    cat <<EOF
用法: $0 [选项]
选项:
  无参数              安装 Docker 并部署所有应用
  --install           仅安装 Docker
  --deploy APP        仅部署指定应用
  --uninstall APP     卸载指定应用并删除数据
  --backup APP        备份指定应用到 /tmp
  --list              列出所有可管理的应用
  --help              显示此帮助

可部署的应用:
  wordpress, nextcloud, gitea, uptime-kuma, portainer
  phpmyadmin, redis-commander, minio, lskypro
  easyimage, nginxpm, vaultwarden, n8n

示例:
  sudo bash $0                        # 完整安装
  sudo bash $0 --deploy wordpress     # 仅部署 WordPress
  sudo bash $0 --uninstall gitea      # 卸载 Gitea
  sudo bash $0 --backup nextcloud     # 备份 Nextcloud
  sudo bash $0 --list                 # 查看应用状态
EOF
    exit 0
}

# ── 列出应用 ─────────────────────────────────────────────────
list_apps() {
    echo -e "${CYAN}可管理的应用:${NC}"
    echo "  wordpress, nextcloud, gitea, uptime-kuma, portainer"
    echo "  phpmyadmin, redis-commander, minio, lskypro"
    echo "  easyimage, nginxpm, vaultwarden, n8n"
    echo -e "\n${CYAN}已部署的应用:${NC}"
    if [ -d "$BASE_DIR" ]; then
        for dir in "$BASE_DIR"/*/; do
            app=$(basename "$dir")
            if [ -f "$dir/docker-compose.yml" ]; then
                # FIX #6: 避免模板字符串在旧版本报错，改用 --format json + 兜底
                status=$(cd "$dir" && docker compose ps --format json 2>/dev/null \
                    | grep -o '"State":"[^"]*"' | head -1 | cut -d'"' -f4 \
                    || echo "unknown")
                [ -z "$status" ] && status="stopped"
                echo -e "  ${GREEN}$app${NC} - $status"
            fi
        done
    fi
    exit 0
}

# ── 系统检查 ─────────────────────────────────────────────────
check_system() {
    local mem=$(free -m | awk '/^Mem:/{print $2}')
    local disk=$(df -m /opt | awk 'NR==2{print $4}')

    [ "$mem" -lt 1024 ] && warn "内存不足 1GB（当前 ${mem}MB），可能影响性能"
    [ "$disk" -lt 5120 ] && warn "磁盘空间不足 5GB（剩余 ${disk}MB），建议扩展空间"

    # FIX #8: 兼容 Debian 衍生版（raspbian、linuxmint、kali 等）
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "${ID_LIKE:-$ID}" in
            *ubuntu*|*debian*) return 0 ;;
        esac
        case "$ID" in
            ubuntu|debian|raspbian|linuxmint|kali|pop) return 0 ;;
            *) error "仅支持 Ubuntu/Debian 系系统，当前系统: $ID" ;;
        esac
    else
        error "无法检测系统发行版"
    fi
}

# ── Docker Compose 启动包装 ─────────────────────────────────
run_compose() {
    local dir="$1"
    local name="$2"
    cd "$dir"
    if docker compose up -d; then
        log "$name 启动成功"
    else
        error "无法启动 $name，请检查 $dir 目录"
    fi
    cd - > /dev/null
}

# ============================================================
# 1. 安装 / 更新 Docker
# ============================================================
install_docker() {
    header "安装 / 更新 Docker Engine"

    if command -v docker &>/dev/null; then
        CURRENT=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
        warn "检测到已安装 Docker（版本 $CURRENT），执行更新..."
    fi

    . /etc/os-release

    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg lsb-release

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/${ID} $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    systemctl enable --now docker

    DOCKER_VER=$(docker version --format '{{.Server.Version}}')
    COMPOSE_VER=$(docker compose version --short)
    log "Docker        $DOCKER_VER"
    log "Docker Compose $COMPOSE_VER"

    if command -v ufw &>/dev/null && ufw status | grep -q inactive; then
        warn "检测到 ufw 未启用，建议执行: ufw enable && ufw allow 22/tcp"
    fi
}

# ============================================================
# 2. 生成随机密码工具
# ============================================================
# FIX #1: 使用 base64 避免特殊字符过滤后长度不足，再截取字母数字
randpw() {
    local length="${1:-24}"
    # 用 base64 保证充足字节，再过滤掉非字母数字字符，取够长度
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$length"
    echo  # 补换行，方便 $() 捕获时不留尾部空白
}

# 生成含特殊字符的强密码（用于 admin token 等场景）
randpw_strong() {
    local length="${1:-32}"
    tr -dc 'A-Za-z0-9!@#$%^&*_+-' </dev/urandom | head -c "$length"
    echo
}

# ============================================================
# 3. 备份应用
# ============================================================
backup_app() {
    local app="$1"
    local dir="$BASE_DIR/$app"
    local backup_file="/tmp/${app}_$(date +%Y%m%d_%H%M%S).tar.gz"

    if [ ! -d "$dir" ]; then
        error "应用 $app 未部署，目录 $dir 不存在"
    fi

    header "备份 $app"

    # FIX #5: 用 trap 保证无论 tar 成功或失败，容器都会重新启动
    (cd "$dir" && docker compose stop) 2>/dev/null || true

    _backup_restart() {
        (cd "$dir" && docker compose start) 2>/dev/null || \
            warn "$app 容器重启失败，请手动执行: docker compose -f $dir/docker-compose.yml start"
    }
    trap _backup_restart EXIT

    tar -czf "$backup_file" -C "$(dirname "$dir")" "$(basename "$dir")"

    # tar 成功后取消 trap，由下面的正常流程重启
    trap - EXIT
    _backup_restart

    local size
    size=$(du -h "$backup_file" | cut -f1)
    log "已备份 $app 到 $backup_file (大小: $size)"
}

# ============================================================
# 4. 卸载应用
# ============================================================
uninstall_app() {
    local app="$1"
    local dir="$BASE_DIR/$app"

    if [ ! -d "$dir" ]; then
        error "应用 $app 未部署，目录 $dir 不存在"
    fi

    header "卸载 $app"

    if [ -f "$dir/docker-compose.yml" ]; then
        (cd "$dir" && docker compose down -v --remove-orphans) || warn "容器停止失败，继续清理..."
    fi

    if [ -f "$dir/.env" ]; then
        cp "$dir/.env" "/tmp/${app}_env_backup_$(date +%Y%m%d)" 2>/dev/null || true
        log "凭据已备份到 /tmp/${app}_env_backup_$(date +%Y%m%d)"
    fi

    rm -rf "$dir"
    log "已卸载 $app 并删除所有数据"
}

# ============================================================
# 5. WordPress（含 MariaDB + Redis）
# ============================================================
deploy_wordpress() {
    header "部署 WordPress"
    local DIR="$BASE_DIR/wordpress"
    mkdir -p "$DIR"/{data,db,redis,uploads}

    local DB_ROOT_PW; DB_ROOT_PW=$(randpw)
    local DB_PW; DB_PW=$(randpw)

    cat > "$DIR/.env" <<EOF
WORDPRESS_DB_ROOT_PASSWORD=$DB_ROOT_PW
WORDPRESS_DB_PASSWORD=$DB_PW
WORDPRESS_DB_NAME=wordpress
WORDPRESS_DB_USER=wpuser
EOF

    cat > "$DIR/docker-compose.yml" <<'YAML'
services:
  db:
    image: mariadb:11
    restart: unless-stopped
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
      - ./uploads/php-uploads.ini:/usr/local/etc/php/conf.d/uploads.ini:ro
    networks: [wp_net]

  nginx:
    image: nginx:alpine
    restart: unless-stopped
    depends_on: [wordpress]
    volumes:
      - ./data:/var/www/html:ro
      - ./uploads/nginx-wp.conf:/etc/nginx/conf.d/default.conf:ro
    networks: [wp_net]
    ports:
      - "127.0.0.1:8080:80"

networks:
  wp_net:
    driver: bridge
YAML

    cat > "$DIR/uploads/php-uploads.ini" <<'INI'
upload_max_filesize = 2048M
post_max_size       = 2048M
memory_limit        = 1024M
max_execution_time  = 600
max_input_time      = 600
max_input_vars      = 10000
INI

    cat > "$DIR/uploads/nginx-wp.conf" <<'NGINX'
server {
    listen 80;
    root /var/www/html;
    index index.php index.html;
    client_max_body_size 2048M;

    location / {
        try_files $uri $uri/ /index.php?$args;
    }
    location ~ \.php$ {
        fastcgi_pass  wordpress:9000;
        fastcgi_index index.php;
        include       fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_read_timeout 600;
    }
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2)$ {
        expires max;
        log_not_found off;
    }
}
NGINX

    run_compose "$DIR" "WordPress"
    log "WordPress 已启动 → http://127.0.0.1:8080  （在外部 nginx 反代此端口）"
    log "凭据已保存至 $DIR/.env"
}

# ============================================================
# 6. Nextcloud（含 MariaDB + Redis）
# ============================================================
deploy_nextcloud() {
    header "部署 Nextcloud"
    local DIR="$BASE_DIR/nextcloud"
    mkdir -p "$DIR"/{data,db,redis,config,apps}

    local DB_ROOT_PW; DB_ROOT_PW=$(randpw)
    local DB_PW; DB_PW=$(randpw)
    local ADMIN_PW; ADMIN_PW=$(randpw 20)

    cat > "$DIR/.env" <<EOF
MYSQL_ROOT_PASSWORD=$DB_ROOT_PW
MYSQL_PASSWORD=$DB_PW
NEXTCLOUD_ADMIN_PASSWORD=$ADMIN_PW
EOF

    # FIX #7: nginx 容器补充挂载 nextcloud 应用根目录（静态资源服务需要）
    cat > "$DIR/docker-compose.yml" <<'YAML'
services:
  db:
    image: mariadb:11
    restart: unless-stopped
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
      - nextcloud_root:/var/www/html
      - ./data:/var/www/html/data
      - ./config:/var/www/html/config
      - ./apps:/var/www/html/custom_apps
    networks: [nc_net]

  nginx:
    image: nginx:alpine
    restart: unless-stopped
    depends_on: [nextcloud]
    volumes:
      # FIX #7: 挂载应用根目录，确保 nginx 能直接服务静态资源（CSS/JS/图片等）
      - nextcloud_root:/var/www/html:ro
      - ./data:/var/www/html/data:ro
      - ./config:/var/www/html/config:ro
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    networks: [nc_net]
    ports:
      - "127.0.0.1:8081:80"

  cron:
    image: nextcloud:production-fpm-alpine
    restart: unless-stopped
    depends_on: [nextcloud]
    volumes:
      - nextcloud_root:/var/www/html
      - ./data:/var/www/html/data
      - ./config:/var/www/html/config
    entrypoint: /cron.sh
    networks: [nc_net]

volumes:
  # 命名卷：nextcloud 容器写入的应用文件（核心代码、插件等）
  # nginx 和 cron 通过共享此卷访问，保证三者看到同一份文件
  nextcloud_root:

networks:
  nc_net:
    driver: bridge
YAML

    cat > "$DIR/nginx.conf" <<'NGINX'
upstream php-handler { server nextcloud:9000; }
server {
    listen 80;
    root /var/www/html;
    client_max_body_size 2048M;
    add_header Strict-Transport-Security "max-age=15768000" always;

    location = /robots.txt { allow all; log_not_found off; access_log off; }
    location ^~ /.well-known { return 301 /index.php$uri; }

    location / {
        rewrite ^ /index.php;
    }
    location ~ ^\/(?:build|tests|config|lib|3rdparty|templates|data)\/ { deny all; }
    location ~ ^\/(?:\.|autotest|occ|issue|indie|db_|console) { deny all; }

    location ~ ^\/(?:index|remote|public|cron|core\/ajax\/update|status|ocs\/v[12]|updater\/.+|oc[ms]-provider\/.+)\.php(?:$|\/) {
        fastcgi_split_path_info ^(.+?\.php)(\/.*|)$;
        fastcgi_pass php-handler;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $fastcgi_path_info;
        fastcgi_read_timeout 600;
    }

    location ~ ^\/(?:updater|oc[ms]-provider)(?:$|\/) {
        try_files $uri/ =404;
        index index.php;
    }

    location ~* \.(?:css|js|woff2|svg|gif|map)$ {
        try_files $uri /index.php$request_uri;
        expires 6M;
    }
    location ~* \.(?:png|html|ttf|ico|jpg|jpeg|bcmap|mp4|webm)$ {
        try_files $uri /index.php$request_uri;
    }
}
NGINX

    run_compose "$DIR" "Nextcloud"
    log "Nextcloud 已启动 → http://127.0.0.1:8081"
    log "管理员: admin / $(grep NEXTCLOUD_ADMIN_PASSWORD "$DIR/.env" | cut -d= -f2)"
}

# ============================================================
# 7. Gitea（Git 服务，含 PostgreSQL）
# ============================================================
deploy_gitea() {
    header "部署 Gitea"
    local DIR="$BASE_DIR/gitea"
    mkdir -p "$DIR"/{data,db}

    local DB_PW; DB_PW=$(randpw)
    cat > "$DIR/.env" <<EOF
POSTGRES_PASSWORD=$DB_PW
EOF

    cat > "$DIR/docker-compose.yml" <<'YAML'
services:
  db:
    image: postgres:16-alpine
    restart: unless-stopped
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
      GITEA__picture__MAX_ORIGINAL_FILE_SIZE: 4096
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

    run_compose "$DIR" "Gitea"
    log "Gitea 已启动 → http://127.0.0.1:3000  SSH: 127.0.0.1:2222"
}

# ============================================================
# 8. Uptime Kuma（监控）
# ============================================================
deploy_uptime_kuma() {
    header "部署 Uptime Kuma"
    local DIR="$BASE_DIR/uptime-kuma"
    mkdir -p "$DIR/data"

    cat > "$DIR/docker-compose.yml" <<'YAML'
services:
  uptime-kuma:
    image: louislam/uptime-kuma:latest
    restart: unless-stopped
    volumes:
      - ./data:/app/data
    ports:
      - "127.0.0.1:3001:3001"
YAML

    run_compose "$DIR" "Uptime Kuma"
    log "Uptime Kuma 已启动 → http://127.0.0.1:3001"
}

# ============================================================
# 9. Portainer（Docker 管理 UI）
# ============================================================
deploy_portainer() {
    header "部署 Portainer CE"
    local DIR="$BASE_DIR/portainer"
    mkdir -p "$DIR/data"

    # FIX #4: 明确告知用户挂载 docker.sock 的权限含义
    warn "Portainer 需要挂载 /var/run/docker.sock，该操作赋予容器等同于 root 的 Docker 控制权限。"
    warn "请确保 Portainer 访问入口不对公网直接暴露。"

    cat > "$DIR/docker-compose.yml" <<'YAML'
services:
  portainer:
    image: portainer/portainer-ce:latest
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/data
    ports:
      - "127.0.0.1:9443:9443"
      - "127.0.0.1:9000:9000"
YAML

    run_compose "$DIR" "Portainer"
    log "Portainer 已启动 → http://127.0.0.1:9000  HTTPS: https://127.0.0.1:9443"
}

# ============================================================
# 10. phpMyAdmin（数据库管理）
# ============================================================
deploy_phpmyadmin() {
    header "部署 phpMyAdmin"
    local DIR="$BASE_DIR/phpmyadmin"
    mkdir -p "$DIR"

    cat > "$DIR/docker-compose.yml" <<'YAML'
services:
  phpmyadmin:
    image: phpmyadmin:latest
    restart: unless-stopped
    environment:
      PMA_ARBITRARY: 1
      PMA_ABSOLUTE_URI: "http://localhost/pma/"
      UPLOAD_LIMIT: 2048M
      MEMORY_LIMIT: 1024M
      MAX_EXECUTION_TIME: 600
    ports:
      - "127.0.0.1:8082:80"
YAML

    run_compose "$DIR" "phpMyAdmin"
    log "phpMyAdmin 已启动 → http://127.0.0.1:8082"
}

# ============================================================
# 11. Redis Commander（Redis GUI）
# ============================================================
deploy_redis_commander() {
    header "部署 Redis Commander"
    local DIR="$BASE_DIR/redis-commander"
    mkdir -p "$DIR"

    cat > "$DIR/docker-compose.yml" <<'YAML'
services:
  redis-commander:
    image: rediscommander/redis-commander:latest
    restart: unless-stopped
    environment:
      REDIS_HOSTS: "local:host.docker.internal:6379"
    ports:
      - "127.0.0.1:8083:8081"
    extra_hosts:
      - "host.docker.internal:host-gateway"
YAML

    run_compose "$DIR" "Redis Commander"
    log "Redis Commander 已启动 → http://127.0.0.1:8083"
}

# ============================================================
# 12. MinIO（对象存储）
# ============================================================
deploy_minio() {
    header "部署 MinIO"
    local DIR="$BASE_DIR/minio"
    mkdir -p "$DIR/data"

    local ACCESS_KEY="admin"
    local SECRET_KEY; SECRET_KEY=$(randpw 32)
    cat > "$DIR/.env" <<EOF
MINIO_ROOT_USER=$ACCESS_KEY
MINIO_ROOT_PASSWORD=$SECRET_KEY
EOF

    cat > "$DIR/docker-compose.yml" <<'YAML'
services:
  minio:
    image: minio/minio:latest
    restart: unless-stopped
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: ${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
    volumes:
      - ./data:/data
    ports:
      - "127.0.0.1:9002:9000"
      - "127.0.0.1:9001:9001"
    networks: [minio_net]
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 30s
      timeout: 20s
      retries: 3

networks:
  minio_net:
    driver: bridge
YAML

    run_compose "$DIR" "MinIO"
    log "MinIO 已启动"
    log "API: http://127.0.0.1:9002"
    log "控制台: http://127.0.0.1:9001"
    log "Access Key: $ACCESS_KEY"
    log "Secret Key: $SECRET_KEY"
}

# ============================================================
# 13. Lsky Pro（兰空图床，使用 MariaDB）
# ============================================================
deploy_lskypro() {
    header "部署 Lsky Pro 图床"
    local DIR="$BASE_DIR/lskypro"
    mkdir -p "$DIR"/{data,config,db}

    local DB_ROOT_PW; DB_ROOT_PW=$(randpw)
    local DB_PW; DB_PW=$(randpw)
    cat > "$DIR/.env" <<EOF
MARIADB_ROOT_PASSWORD=$DB_ROOT_PW
MARIADB_PASSWORD=$DB_PW
EOF

    cat > "$DIR/docker-compose.yml" <<'YAML'
services:
  lskypro:
    image: daryl11/lsky-pro:latest
    restart: unless-stopped
    environment:
      - PUID=1000
      - PGID=1000
    volumes:
      - ./data:/var/www/html
      - ./config:/var/www/html/config
    ports:
      - "127.0.0.1:8085:80"
    depends_on:
      lskypro-db:
        condition: service_healthy
    networks: [lskypro_net]

  lskypro-db:
    image: mariadb:11
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      MARIADB_DATABASE: lskypro
      MARIADB_USER: lskypro
      MARIADB_PASSWORD: ${MARIADB_PASSWORD}
    volumes:
      - ./db:/var/lib/mysql
    networks: [lskypro_net]
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 5

networks:
  lskypro_net:
    driver: bridge
YAML

    run_compose "$DIR" "Lsky Pro"
    log "Lsky Pro 已启动 → http://127.0.0.1:8085"
    log "数据库: lskypro / lskypro / $DB_PW"
}

# ============================================================
# 14. EasyImage（轻量图床）
# ============================================================
deploy_easyimage() {
    header "部署 EasyImage 图床"
    local DIR="$BASE_DIR/easyimage"
    mkdir -p "$DIR"/{data,config}

    cat > "$DIR/docker-compose.yml" <<'YAML'
services:
  easyimage:
    image: ddsderek/easyimage:latest
    restart: unless-stopped
    environment:
      TZ: Asia/Shanghai
      PUID: 1000
      PGID: 1000
    volumes:
      - ./data:/app/web/i
      - ./config:/app/web/config
    ports:
      - "127.0.0.1:8086:80"
    networks: [easyimage_net]

networks:
  easyimage_net:
    driver: bridge
YAML

    run_compose "$DIR" "EasyImage"
    log "EasyImage 已启动 → http://127.0.0.1:8086"
}

# ============================================================
# 15. Nginx Proxy Manager（反代管理）
# ============================================================
deploy_nginxpm() {
    header "部署 Nginx Proxy Manager"
    local DIR="$BASE_DIR/nginx-proxy-manager"
    mkdir -p "$DIR"/{data,letsencrypt}

    # FIX #3: 明确告知 80/443 会绑定到所有网卡（对外暴露）
    warn "Nginx Proxy Manager 将监听 0.0.0.0:80 和 0.0.0.0:443（公网可达）。"
    warn "这是反代网关的预期行为，请在部署后立即修改默认管理员密码（admin@example.com / changeme）。"

    cat > "$DIR/docker-compose.yml" <<'YAML'
services:
  nginx-proxy-manager:
    image: jc21/nginx-proxy-manager:latest
    restart: unless-stopped
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    ports:
      # 以下两个端口会绑定到所有网卡（公网可达），这是反代网关的预期行为
      - "80:80"
      - "443:443"
      # 管理界面仅绑定本地，需通过 SSH 隧道或反代访问
      - "127.0.0.1:81:81"
    networks: [npm_net]

networks:
  npm_net:
    driver: bridge
YAML

    run_compose "$DIR" "Nginx Proxy Manager"
    log "Nginx Proxy Manager 已启动"
    log "管理界面 → http://127.0.0.1:81"
    log "默认账号: admin@example.com / changeme  ← 请立即修改！"
}

# ============================================================
# 16. Vaultwarden（密码管理）
# ============================================================
deploy_vaultwarden() {
    header "部署 Vaultwarden"
    local DIR="$BASE_DIR/vaultwarden"
    mkdir -p "$DIR/data"

    # FIX #2: Admin Token 使用 argon2 哈希存储
    # 先生成原始 token，再用 vaultwarden 自身工具生成哈希
    local RAW_TOKEN; RAW_TOKEN=$(randpw_strong 48)

    # 尝试用 vaultwarden 容器生成 argon2 哈希（需要 docker 已就绪）
    local HASHED_TOKEN
    HASHED_TOKEN=$(docker run --rm vaultwarden/server:latest \
        /vaultwarden hash --preset owasp 2>/dev/null <<< "$RAW_TOKEN" \
        | grep -oP '(?<=Hash: ).*' || true)

    if [ -z "$HASHED_TOKEN" ]; then
        warn "无法生成 argon2 哈希（可能镜像尚未拉取），将使用明文 token。"
        warn "建议在服务启动后手动执行:"
        warn "  docker run --rm vaultwarden/server:latest /vaultwarden hash --preset owasp"
        warn "  然后将输出的 Hash 替换 $DIR/.env 中的 ADMIN_TOKEN，并重启容器。"
        HASHED_TOKEN="$RAW_TOKEN"
    else
        log "Admin Token 已使用 argon2 哈希存储"
    fi

    cat > "$DIR/.env" <<EOF
# 登录管理面板时使用下方「原始 Token」，.env 中存储的是其 argon2 哈希
# 原始 Token（请妥善保管，勿提交到版本库）:
# ADMIN_TOKEN_RAW=$RAW_TOKEN
ADMIN_TOKEN=$HASHED_TOKEN
EOF

    # 同时将原始 token 单独存一份，权限收窄
    echo "$RAW_TOKEN" > "$DIR/.admin_token_raw"
    chmod 600 "$DIR/.admin_token_raw"
    log "原始 Admin Token 已单独保存至 $DIR/.admin_token_raw（权限 600）"

    cat > "$DIR/docker-compose.yml" <<'YAML'
services:
  vaultwarden:
    image: vaultwarden/server:latest
    restart: unless-stopped
    environment:
      ADMIN_TOKEN: ${ADMIN_TOKEN}
      SIGNUPS_ALLOWED: "false"
      WEBSOCKET_ENABLED: "true"
    volumes:
      - ./data:/data
    ports:
      - "127.0.0.1:8087:80"
    networks: [vw_net]

networks:
  vw_net:
    driver: bridge
YAML

    run_compose "$DIR" "Vaultwarden"
    log "Vaultwarden 已启动 → http://127.0.0.1:8087"
    log "管理面板: http://127.0.0.1:8087/admin"
    log "登录用原始 Token（见 $DIR/.admin_token_raw）"
}

# ============================================================
# 17. N8N（工作流自动化）
# ============================================================
deploy_n8n() {
    header "部署 N8N"
    local DIR="$BASE_DIR/n8n"
    mkdir -p "$DIR/data"

    local ENCRYPTION_KEY; ENCRYPTION_KEY=$(randpw 32)
    cat > "$DIR/.env" <<EOF
N8N_ENCRYPTION_KEY=$ENCRYPTION_KEY
EOF

    cat > "$DIR/docker-compose.yml" <<'YAML'
services:
  n8n:
    image: n8nio/n8n:latest
    restart: unless-stopped
    environment:
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      N8N_HOST: localhost
      N8N_PORT: 5678
      N8N_PROTOCOL: http
      NODE_ENV: production
      WEBHOOK_URL: http://localhost/
    volumes:
      - ./data:/home/node/.n8n
    ports:
      - "127.0.0.1:5678:5678"
    networks: [n8n_net]

networks:
  n8n_net:
    driver: bridge
YAML

    run_compose "$DIR" "N8N"
    log "N8N 已启动 → http://127.0.0.1:5678"
    log "Encryption Key: $ENCRYPTION_KEY"
}

# ============================================================
# 18. 打印汇总
# ============================================================
print_summary() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗"
    echo -e "║              🐳  部署完成 — 端口汇总                    ║"
    echo -e "╠══════════════════════════════════════════════════════════╣"
    echo -e "║  WordPress      → http://127.0.0.1:8080                ║"
    echo -e "║  Nextcloud      → http://127.0.0.1:8081                ║"
    echo -e "║  Gitea          → http://127.0.0.1:3000                ║"
    echo -e "║  Uptime Kuma   → http://127.0.0.1:3001                ║"
    echo -e "║  Portainer      → http://127.0.0.1:9000                ║"
    echo -e "║  phpMyAdmin     → http://127.0.0.1:8082                ║"
    echo -e "║  Redis Cmd      → http://127.0.0.1:8083                ║"
    echo -e "║  MinIO Console  → http://127.0.0.1:9001                ║"
    echo -e "║  Lsky Pro       → http://127.0.0.1:8085                ║"
    echo -e "║  EasyImage      → http://127.0.0.1:8086                ║"
    echo -e "║  Nginx PM       → http://127.0.0.1:81                  ║"
    echo -e "║  Vaultwarden    → http://127.0.0.1:8087                ║"
    echo -e "║  N8N            → http://127.0.0.1:5678                ║"
    echo -e "╠══════════════════════════════════════════════════════════╣"
    echo -e "║  凭据文件位置: /opt/docker-apps/<app>/.env              ║"
    echo -e "║  在外部 nginx 将以上端口逐一反代即可对外提供服务        ║"
    echo -e "╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ============================================================
# 主流程
# ============================================================
main() {
    if [[ $# -gt 0 ]]; then
        case "$1" in
            --install)
                check_system
                install_docker
                exit 0
                ;;
            --deploy)
                [ -z "${2:-}" ] && error "请指定应用名称，使用 --list 查看可用应用"
                check_system
                install_docker
                case "$2" in
                    wordpress) deploy_wordpress ;;
                    nextcloud) deploy_nextcloud ;;
                    gitea) deploy_gitea ;;
                    uptime-kuma) deploy_uptime_kuma ;;
                    portainer) deploy_portainer ;;
                    phpmyadmin) deploy_phpmyadmin ;;
                    redis-commander) deploy_redis_commander ;;
                    minio) deploy_minio ;;
                    lskypro) deploy_lskypro ;;
                    easyimage) deploy_easyimage ;;
                    nginxpm) deploy_nginxpm ;;
                    vaultwarden) deploy_vaultwarden ;;
                    n8n) deploy_n8n ;;
                    *) error "未知应用: $2，使用 --list 查看可用应用" ;;
                esac
                exit 0
                ;;
            --uninstall)
                [ -z "${2:-}" ] && error "请指定应用名称"
                uninstall_app "$2"
                exit 0
                ;;
            --backup)
                [ -z "${2:-}" ] && error "请指定应用名称"
                backup_app "$2"
                exit 0
                ;;
            --list)
                list_apps
                ;;
            --help|-h)
                usage
                ;;
            *)
                error "未知选项: $1，使用 --help 查看帮助"
                ;;
        esac
    fi

    check_system
    install_docker

    # 核心应用
    deploy_wordpress
    deploy_nextcloud
    deploy_gitea
    deploy_uptime_kuma
    deploy_portainer
    deploy_phpmyadmin
    deploy_redis_commander

    # 图床相关
    deploy_minio
    deploy_lskypro
    deploy_easyimage

    # 工具类
    deploy_nginxpm
    deploy_vaultwarden
    deploy_n8n

    print_summary
}

main "$@"
