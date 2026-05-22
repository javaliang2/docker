使用方法

chmod +x setup-docker-apps.sh

sudo bash setup-docker-apps.sh

怎么添加新应用？只需两步
第一步：在 APP_LIST 数组加一行：

"myapp | MyApp名称 | 8090 | 一句话描述"


第二步：实现对应函数（复制任意一个 deploy_xxx() 改改即可）：

deploy_myapp() {
  local DIR="$BASE_DIR/myapp"
  mkdir -p "$DIR/data"
  cat > "$DIR/docker-compose.yml" << 'YAML'
  # ... 你的 compose 配置
YAML
  ( cd "$DIR" && docker compose up -d )
  log "MyApp → http://127.0.0.1:8090"
}

升级怎么用？

# 升级全部（拉最新镜像 → 重建有变更的容器 → 清理旧镜像）
sudo bash setup-docker-apps.sh upgrade all

# 只升级某一个应用
sudo bash setup-docker-apps.sh upgrade wordpress
sudo bash setup-docker-apps.sh upgrade alist

# 查看所有应用当前运行状态
sudo bash setup-docker-apps.sh status

