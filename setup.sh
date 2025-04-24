#!/bin/bash
set -e

###############################################################################
# Script cài đặt N8N (kèm Postgres, Redis, Docker, SSL thủ công v.v.)
# Dùng được cả cho domain chính lẫn subdomain:
#   - Hỏi người dùng domain (VD: zenpr.net)
#   - Hỏi subdomain (nếu để trống => cài trên domain chính)
#   - Người dùng paste chứng chỉ SSL (certificate.crt & private.key)
#   - Script tạo file cấu hình Nginx, Docker Compose, ...
# Đã tối ưu cho máy 2 core 4.5GB RAM
###############################################################################

# Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then
  echo "Vui lòng chạy script với quyền root (sudo)."
  exit 1
fi

###############################################################################
# Thu thập thông tin từ người dùng
###############################################################################
echo "======================================"
echo "  CÀI ĐẶT N8N BÁN TỰ ĐỘNG BY ZEN"
echo "======================================"
echo ""
read -p "Nhập domain chính (ví dụ: zenpr.net): " DOMAIN_NAME
read -p "Nhập subdomain (để trống nếu muốn cài trên domain chính): " SUBDOMAIN

# Xác định HOSTNAME
if [ -z "$SUBDOMAIN" ]; then
  HOSTNAME="$DOMAIN_NAME"
else
  HOSTNAME="${SUBDOMAIN}.${DOMAIN_NAME}"
fi

echo ""
echo "Nhập nội dung SSL Certificate (bao gồm cả dòng -----BEGIN CERTIFICATE----- ...)."
echo "Khi paste xong, nhấn Ctrl+D 2 lần để kết thúc."
SSL_CERT_CONTENT="$(</dev/stdin)"   # Đọc mọi thứ cho đến khi Ctrl+D

echo ""
echo "Nhập nội dung SSL Private Key (bao gồm cả dòng -----BEGIN PRIVATE KEY----- ...)."
echo "Khi paste xong, nhấn Ctrl+D 2 lần để kết thúc."
SSL_KEY_CONTENT="$(</dev/stdin)"

echo ""
read -p "Nhập POSTGRES_USER (ví dụ: n8n_zen_demo): " POSTGRES_USER
read -p "Nhập POSTGRES_PASSWORD (ví dụ: n8n_pass_demo): " POSTGRES_PASSWORD
read -p "Nhập POSTGRES_DB (ví dụ: n8n_db_demo): " POSTGRES_DB

###############################################################################
# Update hệ thống, cài đặt các gói cần thiết
###############################################################################
export DEBIAN_FRONTEND=noninteractive

echo "===== Cập nhật hệ thống ====="
apt update -y && apt upgrade -y

echo "===== Cài đặt một số gói cơ bản ====="
apt-get install -y distro-info-data cifs-utils mhddfs unionfs-fuse unzip zip \
                   software-properties-common wget curl gnupg2 ca-certificates lsb-release

###############################################################################
# Tạo thư mục cài đặt N8N
###############################################################################
INSTALL_DIR="/home/${HOSTNAME}"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

###############################################################################
# Cài đặt Nginx từ repo chính thức (nginx.org)
###############################################################################
echo "===== Cài đặt Nginx chính thức ====="
apt install -y curl gnupg2 ca-certificates lsb-release ubuntu-keyring
wget -O- https://nginx.org/keys/nginx_signing.key | gpg --dearmor \
  | tee /etc/apt/trusted.gpg.d/nginx.gpg > /dev/null

# Tạo thư mục .gnupg để tránh warning
mkdir -p -m 600 /root/.gnupg
gpg --dry-run --quiet --import --import-options import-show /etc/apt/trusted.gpg.d/nginx.gpg

echo "deb http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" | tee /etc/apt/sources.list.d/nginx.list
										  
sudo apt update -y

# Xóa Nginx cũ (nếu có)
sudo apt purge -y nginx nginx-common nginx-full nginx-core || true

# Cài Nginx mới
sudo apt install -y nginx
nginx -v

systemctl enable nginx
systemctl start nginx

# Tạo các thư mục cấu hình Nginx nếu chưa có
mkdir -p /etc/nginx/{modules-available,modules-enabled,sites-available,sites-enabled,snippets}

# Backup file cấu hình gốc
if [ -f /etc/nginx/nginx.conf ]; then
  cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
fi

# Ghi file /etc/nginx/nginx.conf - Đã tối ưu cho 2 core và RAM thấp
cat > /etc/nginx/nginx.conf << 'EOL'
user www-data;
worker_processes 2;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
	worker_connections 512;
	# multi_accept on;
}

http {

	## Basic Settings
	sendfile on;
	tcp_nopush on;
	tcp_nodelay on;
	keepalive_timeout 65;
	types_hash_max_size 2048;
	server_tokens off;

	include /etc/nginx/mime.types;
	default_type application/octet-stream;

	## SSL Settings
	ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3;
	ssl_prefer_server_ciphers on;

	## Logging Settings
	access_log /var/log/nginx/access.log;
	error_log /var/log/nginx/error.log;

	## Gzip Settings
	gzip on;
	gzip_comp_level 4;
	gzip_min_length 1000;
	gzip_proxied any;
	gzip_types text/plain text/css application/json application/javascript text/xml application/xml;

	## Connection tuning
	client_body_buffer_size 10K;
	client_header_buffer_size 1k;
	client_max_body_size 15G;
	large_client_header_buffers 2 1k;

	include /etc/nginx/conf.d/*.conf;
	include /etc/nginx/sites-enabled/*;
}
EOL

nginx -t

mkdir -p /etc/systemd/system/nginx.service.d/
echo -e "[Service]\nRestart=always\nRestartSec=10s" > /etc/systemd/system/nginx.service.d/restart.conf
systemctl daemon-reload
systemctl enable nginx
systemctl start nginx
systemctl restart nginx

###############################################################################
# Cài đặt FFmpeg 7.1
###############################################################################
echo "===== Cài đặt FFmpeg 7.1 ====="
# Gỡ bỏ FFmpeg cũ nếu có
sudo apt remove --purge -y ffmpeg || true
sudo apt autoremove -y

# Cài FFmpeg mới
sudo add-apt-repository -y ppa:ubuntuhandbook1/ffmpeg7
sudo apt update -y
sudo apt install -y ffmpeg

###############################################################################
# Cấu hình domain cho Nginx
###############################################################################
CONF_FILE="/etc/nginx/conf.d/${HOSTNAME}.conf"
cat > "$CONF_FILE" <<EOL
server {
    listen 80;
    listen [::]:80;
    server_name ${HOSTNAME};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${HOSTNAME};

    ssl_certificate /etc/nginx/ssl/${HOSTNAME}/certificate.crt;
    ssl_certificate_key /etc/nginx/ssl/${HOSTNAME}/private.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384';
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # Enable gzip compression for text-based resources
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 4;
    gzip_types text/plain text/css application/json application/javascript application/x-javascript text/xml application/xml application/xml+rss text/javascript;

    add_header Content-Security-Policy "frame-ancestors *";
    add_header 'Access-Control-Allow-Origin' '*';
    add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
    add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
    add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range';

    client_max_body_size 15G;

    location / {
        proxy_pass http://127.0.0.1:5678;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Frame-Options SAMEORIGIN;
        proxy_buffers 8 32k;
        proxy_buffer_size 64k;
        client_max_body_size 10M;
        proxy_set_header X-Forwarded-Server \$host;

        proxy_pass_request_headers on;
        proxy_max_temp_file_size 0;
        proxy_connect_timeout 900;
        proxy_send_timeout 900;
        proxy_read_timeout 900;

        proxy_busy_buffers_size 128k;
        proxy_temp_file_write_size 128k;
        proxy_intercept_errors on;
    }
}
EOL

echo "===== Tạo thư mục SSL và ghi chứng chỉ người dùng đã nhập ====="
mkdir -p "/etc/nginx/ssl/${HOSTNAME}/"

# Ghi certificate.crt
echo "$SSL_CERT_CONTENT" | sudo tee "/etc/nginx/ssl/${HOSTNAME}/certificate.crt" > /dev/null
# Ghi private.key
echo "$SSL_KEY_CONTENT"  | sudo tee "/etc/nginx/ssl/${HOSTNAME}/private.key" > /dev/null

sudo systemctl daemon-reload
sudo systemctl restart nginx
service nginx restart

###############################################################################
# Cài đặt Redis
###############################################################################
echo "===== Cài đặt Redis ====="
wget -O- https://packages.redis.io/gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/redis.gpg

mkdir -p -m 600 /root/.gnupg
gpg --dry-run --quiet --import --import-options import-show /etc/apt/trusted.gpg.d/redis.gpg

echo "deb https://packages.redis.io/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/redis.list
sudo apt update -y
sudo apt install -y redis
systemctl enable redis-server
systemctl start redis-server

# Tối ưu cấu hình Redis cho máy có RAM thấp
sed -i 's/^# maxmemory .*/maxmemory 256mb/' /etc/redis/redis.conf
sed -i 's/^# maxmemory-policy .*/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf
systemctl restart redis-server

###############################################################################
# Cài đặt Docker & Docker Compose
###############################################################################
echo "===== Cài đặt Docker & Docker Compose ====="
sudo apt update -y
sudo apt install -y apt-transport-https ca-certificates curl software-properties-common

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
																	 
sudo apt update -y
sudo apt install -y docker-ce docker-compose-plugin
systemctl start docker
systemctl enable docker
sleep 5

# Tối ưu cấu hình Docker cho máy có RAM thấp
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<EOL
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOL
systemctl restart docker

###############################################################################
# Mở các cổng firewall cần thiết
###############################################################################
sudo ufw allow 5432
sudo ufw allow 5678

###############################################################################
# Tạo docker-compose.yml và file .env cho N8N
###############################################################################
echo "===== Tạo file docker-compose.yml và .env cho N8N ====="

# .env
sudo tee "${INSTALL_DIR}/.env" > /dev/null <<EOL
#===== Thông tin tên miền =====#
DOMAIN_NAME=${DOMAIN_NAME}
SUBDOMAIN=${SUBDOMAIN}
HOSTNAME=${HOSTNAME}					
N8N_PROTOCOL=https
NODE_ENV=production

#===== Thông tin Postgres =====#
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=${POSTGRES_DB}

#===== Múi giờ =====#
GENERIC_TIMEZONE=Asia/Ho_Chi_Minh

#===== Lưu trữ file nhị phân (attachments…) trên ổ cứng thay vì DB =====#
N8N_DEFAULT_BINARY_DATA_MODE=filesystem
N8N_DEFAULT_BINARY_DATA_FILESYSTEM_DIRECTORY=/files
N8N_DEFAULT_BINARY_DATA_TEMP_DIRECTORY=/files/temp

#===== Quyền file config =====#
N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true

#===== Dọn dẹp logs/executions cũ =====#
EXECUTIONS_DATA_PRUNE=true
EXECUTIONS_DATA_MAX_AGE=168
EXECUTIONS_DATA_PRUNE_MAX_COUNT=50000

#===== Basic Auth cho n8n =====#
N8N_BASIC_AUTH_USER=Admin
N8N_BASIC_AUTH_PASSWORD=xxxxx
EOL

# Dockerfile (thêm FFmpeg vào container)
sudo tee "${INSTALL_DIR}/Dockerfile" > /dev/null << 'EOL'
FROM n8nio/n8n:latest

USER root

# Cài ffmpeg (alpine) hoặc (debian-based). Tùy theo base image.
# n8nio/n8n:latest hiện tại là alpine, nên:
RUN apk update && apk add --no-cache ffmpeg

USER node
EOL

# docker-compose.yml - Đã tối ưu cho 2 core và 4.5GB RAM
sudo tee "${INSTALL_DIR}/docker-compose.yml" > /dev/null <<EOL
services:
  postgres:
    image: postgres:latest
    container_name: postgres-\${HOSTNAME}
    restart: unless-stopped
    environment:
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB}
    volumes:
      - ./postgres_data:/var/lib/postgresql/data
    ports:
      - "5432:5432"
    command: postgres -c shared_buffers=768MB -c work_mem=32MB -c maintenance_work_mem=128MB -c effective_cache_size=1GB -c random_page_cost=1.1
    deploy:
      resources:
        limits:
          memory: 1G
          cpus: '0.7'

  n8n:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: n8n-\${HOSTNAME}
    restart: unless-stopped
    ports:
      - "5678:5678"
    environment:
      - N8N_HOST=\${HOSTNAME}
      - WEBHOOK_URL=https://\${HOSTNAME}/
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=\${POSTGRES_DB}
      - DB_POSTGRESDB_USER=\${POSTGRES_USER}
      - DB_POSTGRESDB_PASSWORD=\${POSTGRES_PASSWORD}
      - N8N_DEFAULT_BINARY_DATA_MODE=\${N8N_DEFAULT_BINARY_DATA_MODE}
      - N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=\${N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS}
      - N8N_FILE_IO_ALLOWED_DIRECTORIES=/home/node/.n8n
      - GENERIC_TIMEZONE=\${GENERIC_TIMEZONE}
      - EXECUTIONS_DATA_PRUNE=\${EXECUTIONS_DATA_PRUNE}
      - EXECUTIONS_DATA_MAX_AGE=\${EXECUTIONS_DATA_MAX_AGE}
      - EXECUTIONS_DATA_PRUNE_MAX_COUNT=\${EXECUTIONS_DATA_PRUNE_MAX_COUNT}
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=\${N8N_BASIC_AUTH_USER}
      - N8N_BASIC_AUTH_PASSWORD=\${N8N_BASIC_AUTH_PASSWORD}
      - NODE_OPTIONS="--max-old-space-size=1536"
    volumes:
      - ./n8n_data:/home/node/.n8n
      - ./n8n_data/files:/files
      - ./n8n_data/backup:/backup
      - ./n8n_data/shared:/data/shared
      - ./n8n_data/custom_fonts:/home/node/custom_fonts
    depends_on:
      - postgres
    user: "1000:1000"
    deploy:
      resources:
        limits:
          memory: 2G
          cpus: '1.0'
EOL

echo "===== Khởi động lại Docker Compose để áp dụng quyền và cấu hình mới ====="
cd "$INSTALL_DIR"

sudo docker compose pull

# Tắt container (nếu đang chạy)
sudo docker compose down || true

# Chuyển quyền thư mục sang user 1000:1000
sudo chown -R 1000:1000 "$INSTALL_DIR"/*

# Khởi động lại docker compose ở chế độ detached
sudo docker compose up -d

# Tối ưu hiệu suất hệ thống
echo "===== Tối ưu hiệu suất hệ thống ====="

# Giảm swappiness để hạn chế sử dụng swap
echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf

# Tối ưu cho hệ thống có RAM thấp
echo 'vm.dirty_ratio = 10' | sudo tee -a /etc/sysctl.conf
echo 'vm.dirty_background_ratio = 5' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# Điều chỉnh Linux OOM Killer ưu tiên bảo vệ các tiến trình hệ thống quan trọng
echo "* soft nproc 10000" | sudo tee -a /etc/security/limits.conf
echo "* hard nproc 15000" | sudo tee -a /etc/security/limits.conf

echo "===== Đã tạo xong file docker-compose.yml và .env ====="

echo "============================================================================"
echo "Tất cả cài đặt đã hoàn tất."
echo "N8N đang chạy ở thư mục ${INSTALL_DIR}"
echo "Bạn vào thư mục ${INSTALL_DIR} và chạy các lệnh sau:"
echo "  cd ${INSTALL_DIR}"
echo "  docker compose down"
echo "  chown -R 1000:1000 ${INSTALL_DIR}/*"
echo "  docker compose up -d"
echo "============================================================================"
echo "Để nâng cấp N8N mỗi khi có update mới, chạy lần lượt 3 lệnh sau"
echo "  cd ${INSTALL_DIR}"
echo "  docker compose down"
echo "  docker compose build --pull"
echo "  docker compose up -d"
echo "============================================================================"
exit 0
