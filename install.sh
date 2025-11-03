#!/bin/bash
# filepath: install.sh 

# Цвета для красивого CLI
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Лого и версия
LOGO="${CYAN}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃  ${WHITE}MrCerber Network${CYAN} - Настройка VPS v1.0      ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"

# Функции для вывода сообщений
print_logo() {
    clear
    echo -e "$LOGO"
    echo ""
}

print_message() {
    echo -e "${BLUE}[ИНФО]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[УСПЕХ]${NC} $1"
}

print_error() {
    echo -e "${RED}[ОШИБКА]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[ВНИМАНИЕ]${NC} $1"
}

# Проверка root прав
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Этот скрипт должен быть запущен с правами суперпользователя (root)"
        exit 1
    fi
}

# Начальная настройка системы
initial_setup() {
    print_logo
    print_message "Начинаем первичную настройку системы..."
    
    # Обновление системы
    print_message "Обновление пакетов..."
    apt update -y
    apt upgrade -y
    
    # Установка необходимых утилит
    print_message "Установка базовых утилит..."
    apt install -y curl wget git unzip zip nano htop net-tools ncdu \
                   apt-transport-https ca-certificates gnupg lsb-release \
                   software-properties-common python3-pip fail2ban

    # Настройка автоматических обновлений
    print_message "Настройка автоматических обновлений..."
    apt install -y unattended-upgrades apt-listchanges
    dpkg-reconfigure -plow unattended-upgrades
    
    # Настройка timezone
    print_message "Настройка временной зоны..."
    timedatectl set-timezone Europe/Moscow
    
    # Создание нового пользователя
    print_message "Создание нового пользователя..."
    read -p "Введите имя нового пользователя: " username
    
    if id "$username" &>/dev/null; then
        print_warning "Пользователь $username уже существует!"
    else
        adduser $username
        # Добавление в sudo группу
        usermod -aG sudo $username
        print_success "Пользователь $username создан и добавлен в группу sudo!"
    fi
    
    # Настройка SSH для нового пользователя
    print_message "Настройка SSH доступа..."
    mkdir -p /home/$username/.ssh
    touch /home/$username/.ssh/authorized_keys
    chmod 700 /home/$username/.ssh
    chmod 600 /home/$username/.ssh/authorized_keys
    chown -R $username:$username /home/$username/.ssh
    
    read -p "Хотите добавить публичный SSH ключ для нового пользователя? (y/n): " add_key
    if [[ $add_key == "y" || $add_key == "Y" ]]; then
        read -p "Вставьте ваш публичный SSH ключ: " ssh_key
        echo $ssh_key >> /home/$username/.ssh/authorized_keys
        print_success "SSH ключ добавлен!"
    fi

    # Настройка swap-файла, если его нет
    print_message "Проверка и настройка swap-файла..."
    if free | grep -q "Swap"; then
        swap_total=$(free | grep "Swap" | awk '{print $2}')
        if [ $swap_total -gt 0 ]; then
            print_message "Swap уже настроен: $swap_total КБ"
        else
            setup_swap
        fi
    else
        setup_swap
    fi
    
    print_success "Первичная настройка системы завершена!"
}

# Функция для настройки swap-файла
setup_swap() {
    mem_total=$(free -m | grep "Mem" | awk '{print $2}')
    
    # Определим размер swap в зависимости от размера RAM
    if [ $mem_total -le 2048 ]; then
        swap_size=$mem_total
    else
        swap_size=2048
    fi
    
    print_message "Создание swap-файла размером ${swap_size}MB..."
    
    # Создаем swap файл
    fallocate -l ${swap_size}M /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    
    # Добавляем в fstab для автоматического монтирования при загрузке
    echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
    
    # Настройка параметров свопинга
    echo 'vm.swappiness=10' | tee -a /etc/sysctl.conf
    echo 'vm.vfs_cache_pressure=50' | tee -a /etc/sysctl.conf
    sysctl -p
    
    print_success "Swap-файл успешно настроен!"
}

# Функция для проверки DNS конфигурации домена
check_domain_dns() {
    local domain=$1
    local server_ip
    local domain_ip
    
    print_message "Проверка DNS конфигурации для домена $domain..."
    
    # Получение внешнего IP адреса сервера
    server_ip=$(curl -s https://ipv4.icanhazip.com/ || curl -s https://api.ipify.org)
    if [ -z "$server_ip" ]; then
        print_error "Не удалось определить внешний IP адрес сервера"
        return 1
    fi
    
    print_message "IP адрес сервера: $server_ip"
    
    # Проверка A записи для основного домена
    print_message "Проверка A записи для $domain..."
    domain_ip=$(dig +short A $domain @8.8.8.8 | head -n1)
    
    if [ -z "$domain_ip" ]; then
        print_error "A запись для домена $domain не найдена"
        print_message "Убедитесь, что вы настроили DNS запись:"
        echo "  Тип: A"
        echo "  Имя: $domain (или @)"
        echo "  Значение: $server_ip"
        return 1
    fi
    
    if [ "$domain_ip" != "$server_ip" ]; then
        print_warning "A запись для $domain указывает на $domain_ip, но IP сервера $server_ip"
        read -p "Продолжить настройку несмотря на несоответствие DNS? (y/n): " continue_anyway
        if [[ $continue_anyway != "y" && $continue_anyway != "Y" ]]; then
            print_message "Настройте DNS запись и попробуйте снова:"
            echo "  Тип: A"
            echo "  Имя: $domain (или @)"
            echo "  Значение: $server_ip"
            return 1
        fi
    else
        print_success "A запись для $domain настроена корректно ($domain_ip)"
    fi
    
    # Проверка A записи для www поддомена
    print_message "Проверка A записи для www.$domain..."
    www_domain_ip=$(dig +short A www.$domain @8.8.8.8 | head -n1)
    
    if [ -z "$www_domain_ip" ]; then
        print_warning "A запись для www.$domain не найдена"
        print_message "Рекомендуется настроить DNS запись для www:"
        echo "  Тип: A"
        echo "  Имя: www"
        echo "  Значение: $server_ip"
        read -p "Продолжить без www записи? (y/n): " continue_without_www
        if [[ $continue_without_www != "y" && $continue_without_www != "Y" ]]; then
            return 1
        fi
    elif [ "$www_domain_ip" != "$server_ip" ]; then
        print_warning "A запись для www.$domain указывает на $www_domain_ip, но IP сервера $server_ip"
        read -p "Продолжить настройку несмотря на несоответствие DNS для www? (y/n): " continue_anyway_www
        if [[ $continue_anyway_www != "y" && $continue_anyway_www != "Y" ]]; then
            print_message "Настройте DNS запись для www и попробуйте снова:"
            echo "  Тип: A"
            echo "  Имя: www"
            echo "  Значение: $server_ip"
            return 1
        fi
    else
        print_success "A запись для www.$domain настроена корректно ($www_domain_ip)"
    fi
    
    # Дополнительная проверка доступности через HTTP
    print_message "Проверка HTTP доступности домена..."
    if timeout 10 curl -s -I "http://$domain" > /dev/null 2>&1; then
        print_success "Домен $domain доступен по HTTP"
    else
        print_warning "Домен $domain недоступен по HTTP (это нормально, если веб-сервер еще не настроен)"
    fi
    
    return 0
}

# Установка домена и демо-страницы с улучшенной конфигурацией
setup_domain() {
    print_logo
    print_message "Настройка домена и демо-страницы с расширенной конфигурацией..."
    
    # Установка необходимых пакетов
    apt install -y nginx certbot python3-certbot-nginx ssl-cert dnsutils
    
    # Запрос домена
    read -p "Введите ваш домен (например, example.com): " domain_name
    if [ -z "$domain_name" ]; then
        print_error "Домен не указан. Отмена настройки."
        return 1
    fi
    
    # Проверка DNS конфигурации домена
    if ! check_domain_dns "$domain_name"; then
        print_error "Проверка DNS не пройдена. Настройте DNS и попробуйте снова."
        return 1
    fi
    
    echo ""
    read -p "Нажмите Enter для продолжения настройки домена..."
    
    # Создание директорий
    print_message "Создание необходимых директорий..."
    mkdir -p /var/log/nginx/$domain_name
    mkdir -p /var/www/letsencrypt
    mkdir -p /var/www/$domain_name

    # Создание файла с SSL параметрами
    cat > /etc/nginx/ssl-params.conf << EOF
# SSL параметры оптимизации
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers on;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 1d;
ssl_session_tickets off;
ssl_stapling on;
ssl_stapling_verify on;
resolver 8.8.8.8 8.8.4.4 valid=300s;
resolver_timeout 5s;
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload";
add_header X-Frame-Options SAMEORIGIN;
add_header X-Content-Type-Options nosniff;
add_header X-XSS-Protection "1; mode=block";
ssl_dhparam /etc/ssl/certs/dhparam.pem;
EOF

    # Генерация сильных DH параметров для безопасности SSL
    print_message "Генерация DH параметров для улучшенной безопасности SSL (это может занять некоторое время)..."
    openssl dhparam -out /etc/ssl/certs/dhparam.pem 2048

    # Создание временной HTTP-конфигурации для получения SSL сертификата
    print_message "Создание временной HTTP-конфигурации для получения SSL сертификата..."
    cat > /etc/nginx/sites-available/$domain_name << EOF
# Временная HTTP конфигурация для получения SSL сертификата
server {
    listen 80;
    listen [::]:80;
    server_name $domain_name www.$domain_name;
    
    # Логи
    access_log /var/log/nginx/$domain_name/access.log;
    error_log /var/log/nginx/$domain_name/error.log;
    
    # Корневая директория
    root /var/www/$domain_name;
    index index.html index.htm;
    
    # Конфигурация для Let's Encrypt
    location ~ /.well-known/acme-challenge {
        root /var/www/letsencrypt;
        allow all;
    }
    
    # Основная конфигурация
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
    
    # Создание улучшенной демо-страницы с Tailwind CSS
    cat > /var/www/$domain_name/index.html << EOF
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>MrCerber Network</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <meta name="description" content="MrCerber Network - Профессиональные VPS решения">
    <link rel="icon" href="data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 100 100%22><text y=%22.9em%22 font-size=%2290%22>🚀</text></svg>">
</head>
<body class="bg-gradient-to-br from-gray-900 to-gray-800 text-white min-h-screen flex items-center justify-center">
    <div class="max-w-5xl mx-auto p-6 text-center">
        <div class="mb-10">
            <h1 class="text-6xl font-bold mb-4 bg-gradient-to-r from-cyan-400 to-blue-500 bg-clip-text text-transparent">MrCerber Network</h1>
            <p class="text-2xl text-gray-300">Ваш сервер успешно настроен и готов к работе!</p>
            <div class="w-32 h-1 bg-gradient-to-r from-cyan-500 to-blue-500 rounded mx-auto my-6"></div>
        </div>
        
        <div class="grid md:grid-cols-3 gap-8 mb-12">
            <div class="bg-gray-800 bg-opacity-50 backdrop-filter backdrop-blur-lg rounded-xl p-8 shadow-lg border border-gray-700 transform transition-transform hover:scale-105">
                <div class="text-cyan-400 text-4xl mb-4">🔒</div>
                <h3 class="text-2xl font-semibold text-cyan-300 mb-3">Безопасность</h3>
                <p class="text-gray-400">Современные технологии защиты данных и SSL шифрование</p>
            </div>
            <div class="bg-gray-800 bg-opacity-50 backdrop-filter backdrop-blur-lg rounded-xl p-8 shadow-lg border border-gray-700 transform transition-transform hover:scale-105">
                <div class="text-cyan-400 text-4xl mb-4">⚡</div>
                <h3 class="text-2xl font-semibold text-cyan-300 mb-3">Производительность</h3>
                <p class="text-gray-400">Оптимизированные высокоскоростные серверы</p>
            </div>
            <div class="bg-gray-800 bg-opacity-50 backdrop-filter backdrop-blur-lg rounded-xl p-8 shadow-lg border border-gray-700 transform transition-transform hover:scale-105">
                <div class="text-cyan-400 text-4xl mb-4">🔄</div>
                <h3 class="text-2xl font-semibold text-cyan-300 mb-3">Надежность</h3>
                <p class="text-gray-400">Гарантированный аптайм 99.9% и автоматические обновления</p>
            </div>
        </div>
        
        <div class="bg-gray-800 bg-opacity-30 rounded-lg p-8 mb-8 shadow-lg backdrop-filter backdrop-blur-sm">
            <h2 class="text-2xl font-bold text-cyan-300 mb-4">Техническая информация</h2>
            <div class="grid md:grid-cols-2 gap-4 text-left">
                <div>
                    <p><span class="font-semibold">IP адрес:</span> <span id="server-ip" class="text-gray-400">Загрузка...</span></p>
                    <p><span class="font-semibold">Хостнейм:</span> <span id="hostname" class="text-gray-400">Загрузка...</span></p>
                </div>
                <div>
                    <p><span class="font-semibold">Операционная система:</span> <span class="text-gray-400">Ubuntu</span></p>
                    <p><span class="font-semibold">Веб-сервер:</span> <span class="text-gray-400">Nginx с SSL</span></p>
                </div>
            </div>
        </div>
        
        <div class="text-gray-400 text-sm">
            <p>&copy; $(date +%Y) MrCerber Network. Все права защищены.</p>
        </div>
    </div>

    <script>
        // Получение IP адреса и хостнейма
        fetch('https://api.ipify.org?format=json')
            .then(response => response.json())
            .then(data => {
                document.getElementById('server-ip').innerText = data.ip;
            })
            .catch(err => {
                document.getElementById('server-ip').innerText = "Недоступно";
            });

        fetch('/hostname.txt')
            .then(response => response.text())
            .then(data => {
                document.getElementById('hostname').innerText = data.trim();
            })
            .catch(err => {
                document.getElementById('hostname').innerText = "Недоступно";
            });
    </script>
</body>
</html>
EOF

    # Создаем файл с именем хоста
    hostname > /var/www/$domain_name/hostname.txt

    # Настройка прав доступа
    chown -R www-data:www-data /var/www/$domain_name /var/www/letsencrypt
    chmod -R 755 /var/www/$domain_name /var/www/letsencrypt
    
    # Удаление конфигурации по умолчанию если существует
    if [ -f /etc/nginx/sites-enabled/default ]; then
        rm -f /etc/nginx/sites-enabled/default
    fi
    
    # Активация временной HTTP конфигурации
    ln -sf /etc/nginx/sites-available/$domain_name /etc/nginx/sites-enabled/
    
    # Проверка конфигурации Nginx
    print_message "Проверка временной HTTP конфигурации Nginx..."
    nginx -t
    
    if [ $? -ne 0 ]; then
        print_error "Обнаружена ошибка в конфигурации Nginx. Пожалуйста, проверьте настройки."
        return 1
    fi
    
    # Перезапуск Nginx с временной конфигурацией
    systemctl restart nginx
    
    if [ $? -ne 0 ]; then
        print_error "Не удалось запустить Nginx. Проверьте логи: systemctl status nginx"
        return 1
    fi
    
    # Установка SSL сертификата через Certbot
    print_message "Установка SSL сертификата через Certbot..."
    
    # Получение сертификата с помощью webroot
    certbot certonly --webroot -w /var/www/letsencrypt -d $domain_name -d www.$domain_name --non-interactive --agree-tos --email admin@$domain_name
    
    if [ $? -ne 0 ]; then
        print_warning "Не удалось автоматически получить SSL сертификат."
        print_message "Попробуйте выполнить команду вручную:"
        echo "sudo certbot certonly --webroot -w /var/www/letsencrypt -d $domain_name -d www.$domain_name"
        return 1
    fi
    
    print_success "SSL сертификат успешно получен!"
    
    # Создание полной HTTPS конфигурации
    print_message "Создание полной HTTPS конфигурации..."
    cat > /etc/nginx/sites-available/$domain_name << EOF
# Редирект с HTTP на HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name $domain_name www.$domain_name;
    
    # Логи
    access_log /var/log/nginx/$domain_name/access.log;
    error_log /var/log/nginx/$domain_name/error.log;
    
    # Конфигурация для Let's Encrypt
    location ~ /.well-known/acme-challenge {
        root /var/www/letsencrypt;
        allow all;
    }
    
    # Редирект на HTTPS
    location / {
        return 301 https://$domain_name\$request_uri;
    }
}

# Основной HTTPS сервер
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $domain_name;
    
    # Логи
    access_log /var/log/nginx/$domain_name/access.log;
    error_log /var/log/nginx/$domain_name/error.log;
    
    # SSL
    ssl_certificate /etc/letsencrypt/live/$domain_name/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain_name/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/$domain_name/chain.pem;
    
    # Включение оптимизированных SSL параметров
    include /etc/nginx/ssl-params.conf;
    
    # Корневая директория
    root /var/www/$domain_name;
    index index.html index.htm;
    
    # Настройки производительности и кэширования
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|woff|woff2|ttf|eot)$ {
        expires 30d;
        add_header Cache-Control "public, no-transform";
    }
    
    # Защита от доступа к скрытым файлам
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
    
    # Основная конфигурация
    location / {
        try_files \$uri \$uri/ =404;
    }

    # Сжатие ответов
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript application/xml+rss application/atom+xml image/svg+xml;
}

# Редирект с www на non-www
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name www.$domain_name;
    
    # SSL
    ssl_certificate /etc/letsencrypt/live/$domain_name/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain_name/privkey.pem;
    include /etc/nginx/ssl-params.conf;
    
    return 301 https://$domain_name\$request_uri;
}
EOF

    # Финальная проверка конфигурации
    print_message "Финальная проверка HTTPS конфигурации..."
    nginx -t
    
    if [ $? -ne 0 ]; then
        print_error "Ошибка в финальной конфигурации Nginx!"
        return 1
    fi
    
    # Перезапуск с полной конфигурацией
    systemctl restart nginx
    
    if [ $? -ne 0 ]; then
        print_error "Не удалось перезапустить Nginx с HTTPS конфигурацией!"
        return 1
    fi
    
    # Настройка автоматического обновления сертификатов
    print_message "Настройка автоматического обновления SSL сертификатов..."
    
    # Проверяем существование задачи в crontab
    if ! crontab -l 2>/dev/null | grep -q certbot; then
        (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook \"systemctl reload nginx\"") | crontab -
        print_success "Автоматическое обновление SSL настроено!"
    else
        print_message "Задача автообновления SSL уже существует в crontab."
    fi
    
    print_success "Домен $domain_name успешно настроен с оптимизированным Nginx и SSL сертификатом!"
    print_message "Ваш сайт доступен по адресу: https://$domain_name"

    monitor_ssl_certificates
}

monitor_ssl_certificates() {
    print_message "Настройка мониторинга SSL сертификатов..."
    
    # Создаем скрипт мониторинга
    cat > /usr/local/bin/check-ssl-renewal.sh << 'EOF'
#!/bin/bash

# Проверка SSL сертификатов
for domain in $(find /etc/letsencrypt/live -type d -name "*.*"); do
    domain=$(basename $domain)
    
    # Пропускаем служебные директории
    if [ "$domain" == "README" ]; then
        continue
    fi
    
    # Проверка срока действия
    exp_date=$(openssl x509 -in /etc/letsencrypt/live/$domain/cert.pem -noout -enddate | cut -d= -f2)
    exp_epoch=$(date -d "$exp_date" +%s)
    now_epoch=$(date +%s)
    days_left=$(( ($exp_epoch - $now_epoch) / 86400 ))
    
    if [ $days_left -lt 30 ]; then
        # Принудительное обновление
        certbot renew --force-renewal --cert-name $domain
        systemctl reload nginx
        
        # Отправка уведомления (можно настроить через телеграм или email)
        echo "Сертификат для $domain был обновлен. Осталось дней: $days_left" >> /var/log/ssl-renewal.log
    fi
done
EOF

    # Делаем скрипт исполняемым
    chmod +x /usr/local/bin/check-ssl-renewal.sh
    
    # Добавляем в crontab ежедневную проверку
    (crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/check-ssl-renewal.sh") | sort | uniq | crontab -
    
    print_success "Мониторинг SSL настроен!"
}

# Установка Docker
install_docker() {
    print_logo
    print_message "Установка Docker по официальной инструкции..."
    
    # Удаление старых версий
    apt remove -y docker docker-engine docker.io containerd runc || true
    
    # Установка необходимых пакетов
    apt install -y apt-transport-https ca-certificates curl gnupg lsb-release
    
    # Добавление официального GPG ключа Docker
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    
    # Настройка репозитория
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Установка Docker Engine
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    # Добавление пользователя в группу docker
    read -p "Введите имя пользователя для добавления в группу docker: " docker_user
    if id "$docker_user" &>/dev/null; then
        usermod -aG docker $docker_user
        print_success "Пользователь $docker_user добавлен в группу docker!"
    else
        print_error "Пользователь $docker_user не существует!"
    fi
    
    # Проверка установки
    if docker --version &>/dev/null; then
        print_success "Docker успешно установлен: $(docker --version)"
        print_success "Docker Compose: $(docker compose version)"
    else
        print_error "Что-то пошло не так при установке Docker."
    fi
    
    # Запуск тестового контейнера
    print_message "Запуск тестового контейнера..."
    docker run --rm hello-world
    
    print_success "Docker успешно установлен и проверен!"
}

# Функция для копирования SSL сертификатов
copy_ssl_certificates() {
    print_message "Копирование SSL сертификатов в /root/cert/..."
    
    # Создание директории для сертификатов
    mkdir -p /root/cert
    
    # Проверка наличия сертификатов Let's Encrypt
    if [ -d "/etc/letsencrypt/live" ]; then
        # Поиск всех доменов с сертификатами
        for domain_dir in /etc/letsencrypt/live/*/; do
            if [ -d "$domain_dir" ]; then
                domain_name=$(basename "$domain_dir")
                
                # Пропускаем README файл
                if [ "$domain_name" = "README" ]; then
                    continue
                fi
                
                print_message "Копирование сертификатов для домена: $domain_name"
                
                # Создание директории для домена
                mkdir -p "/root/cert/$domain_name"
                
                # Копирование файлов сертификатов
                if [ -f "$domain_dir/fullchain.pem" ]; then
                    cp "$domain_dir/fullchain.pem" "/root/cert/$domain_name/"
                    print_success "Скопирован fullchain.pem для $domain_name"
                fi
                
                if [ -f "$domain_dir/privkey.pem" ]; then
                    cp "$domain_dir/privkey.pem" "/root/cert/$domain_name/"
                    print_success "Скопирован privkey.pem для $domain_name"
                fi
                
                if [ -f "$domain_dir/cert.pem" ]; then
                    cp "$domain_dir/cert.pem" "/root/cert/$domain_name/"
                    print_success "Скопирован cert.pem для $domain_name"
                fi
                
                if [ -f "$domain_dir/chain.pem" ]; then
                    cp "$domain_dir/chain.pem" "/root/cert/$domain_name/"
                    print_success "Скопирован chain.pem для $domain_name"
                fi
                
                # Установка правильных прав доступа
                chmod 600 "/root/cert/$domain_name/"*.pem
                chown root:root "/root/cert/$domain_name/"*.pem
            fi
        done
        
        # Вывод информации о скопированных сертификатах
        print_success "SSL сертификаты скопированы в /root/cert/"
        print_message "Структура директории /root/cert/:"
        ls -la /root/cert/
        
        print_message "Для использования в 3X-UI:"
        echo "Путь к сертификату: /root/cert/[имя_домена]/fullchain.pem"
        echo "Путь к приватному ключу: /root/cert/[имя_домена]/privkey.pem"
    else
        print_warning "SSL сертификаты Let's Encrypt не найдены в /etc/letsencrypt/live/"
        print_message "Убедитесь, что вы сначала настроили домен с SSL (опция 2)"
    fi
}

# Установка 3X-UI
install_3xui() {
    print_logo
    print_message "Установка 3X-UI..."
    
    # Проверка наличия SSL сертификатов и их копирование
    read -p "Хотите скопировать существующие SSL сертификаты в /root/cert/ перед установкой? (y/n): " copy_ssl
    if [[ $copy_ssl == "y" || $copy_ssl == "Y" ]]; then
        copy_ssl_certificates
        echo ""
        read -p "Нажмите Enter для продолжения установки 3X-UI..."
    fi
    
    # Установка с использованием официального скрипта
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
    
    print_success "3X-UI установлен. Вы можете управлять им через веб-интерфейс."
    
    if [[ $copy_ssl == "y" || $copy_ssl == "Y" ]]; then
        echo ""
        print_message "SSL сертификаты доступны в /root/cert/ для настройки в 3X-UI"
        print_message "В настройках панели используйте пути:"
        echo "  - Сертификат: /root/cert/[имя_домена]/fullchain.pem"
        echo "  - Приватный ключ: /root/cert/[имя_домена]/privkey.pem"
    fi
}

# Установка и настройка UFW
setup_ufw() {
    print_logo
    print_message "Настройка файрвола UFW..."
    
    # Установка UFW если не установлен
    apt install -y ufw
    
    # Настройка базовых правил
    print_message "Настройка базовых правил безопасности..."
    
    # Разрешить SSH
    ufw allow ssh
    
    # Разрешить HTTP и HTTPS
    ufw allow 80/tcp
    ufw allow 443/tcp
    
    # Спросить о дополнительных портах
    read -p "Хотите открыть дополнительные порты? (y/n): " add_ports
    if [[ $add_ports == "y" || $add_ports == "Y" ]]; then
        while true; do
            read -p "Введите номер порта для открытия (или 'q' для завершения): " port
            
            if [[ $port == "q" || $port == "Q" ]]; then
                break
            fi
            
            if [[ $port =~ ^[0-9]+$ ]]; then
                read -p "Протокол (tcp/udp/both): " protocol
                
                case $protocol in
                    tcp) ufw allow $port/tcp
                         print_success "Порт $port/tcp открыт" ;;
                    udp) ufw allow $port/udp
                         print_success "Порт $port/udp открыт" ;;
                    both) ufw allow $port
                          print_success "Порт $port (tcp+udp) открыт" ;;
                    *) print_error "Неизвестный протокол. Используйте tcp, udp или both." ;;
                esac
            else
                print_error "Пожалуйста, введите числовое значение порта."
            fi
        done
    fi
    
    # Включение UFW
    print_warning "Включение UFW. Убедитесь, что порт SSH разрешен!"
    ufw --force enable
    
    # Вывод статуса
    ufw status verbose
    
    print_success "UFW настроен и активирован!"
}

# Ручное обновление SSL сертификатов
manual_ssl_renewal() {
    print_logo
    print_message "Ручное обновление SSL сертификатов..."
    
    # Проверка наличия сертификатов
    if [ ! -d "/etc/letsencrypt/live" ]; then
        print_error "SSL сертификаты не найдены. Сначала настройте домен с SSL (опция 2)"
        return 1
    fi
    
    # Показать список доменов с сертификатами
    echo "Найденные домены с SSL сертификатами:"
    domains=()
    i=1
    for domain_dir in /etc/letsencrypt/live/*/; do
        domain_name=$(basename "$domain_dir")
        if [ "$domain_name" != "README" ]; then
            echo "$i) $domain_name"
            domains+=("$domain_name")
            ((i++))
        fi
    done
    
    if [ ${#domains[@]} -eq 0 ]; then
        print_error "Сертификаты не найдены"
        return 1
    fi
    
    echo ""
    echo "Выберите действие:"
    echo "1) Обновить все сертификаты"
    echo "2) Обновить конкретный домен"
    read -p "Ваш выбор (1-2): " renewal_choice
    
    case $renewal_choice in
        1)
            print_message "Обновление всех сертификатов..."
            certbot renew --force-renewal
            if [ $? -eq 0 ]; then
                systemctl reload nginx
                print_success "Все сертификаты успешно обновлены!"
            else
                print_error "Произошла ошибка при обновлении сертификатов"
            fi
            ;;
        2)
            read -p "Введите номер домена для обновления: " domain_number
            if [ $domain_number -ge 1 ] && [ $domain_number -le ${#domains[@]} ]; then
                selected_domain=${domains[$domain_number-1]}
                print_message "Обновление сертификата для домена $selected_domain..."
                certbot renew --force-renewal --cert-name "$selected_domain"
                if [ $? -eq 0 ]; then
                    systemctl reload nginx
                    print_success "Сертификат для $selected_domain успешно обновлен!"
                else
                    print_error "Произошла ошибка при обновлении сертификата"
                fi
            else
                print_error "Неверный номер домена"
            fi
            ;;
        *)
            print_error "Неверный выбор"
            ;;
    esac
    
    # Проверка статуса сертификатов после обновления
    print_message "Статус сертификатов:"
    certbot certificates
}

setup_timezone() {
    print_logo
    print_message "Настройка часового пояса (Timezone)..."
    
    # Показать текущий часовой пояс
    current_timezone=$(timedatectl | grep "Time zone" | awk '{print $3}')
    print_message "Текущий часовой пояс: $current_timezone"
    
    echo ""
    echo "Доступные регионы:"
    echo "1) Europe (Европа)"
    echo "2) Asia (Азия)"
    echo "3) America (Америка)"
    echo "4) Africa (Африка)"
    echo "5) Pacific (Тихий океан)"
    echo "6) Поиск по названию города"
    echo "0) Отмена"
    
    read -p "Выберите регион [0-6]: " region_choice
    
    case $region_choice in
        1) region="Europe" ;;
        2) region="Asia" ;;
        3) region="America" ;;
        4) region="Africa" ;;
        5) region="Pacific" ;;
        6) 
            read -p "Введите название города (например, Moscow): " city
            if timedatectl list-timezones | grep -i "$city" > /dev/null; then
                available_zones=$(timedatectl list-timezones | grep -i "$city")
                echo "Найденные часовые пояса:"
                echo "$available_zones" | nl
                read -p "Выберите номер часового пояса: " zone_number
                timezone=$(echo "$available_zones" | sed -n "${zone_number}p")
            else
                print_error "Город не найден"
                return 1
            fi
            ;;
        0) return 0 ;;
        *) 
            print_error "Неверный выбор"
            return 1
            ;;
    esac
    
    if [ -n "$region" ] && [ -z "$timezone" ]; then
        echo ""
        echo "Доступные города в регионе $region:"
        timedatectl list-timezones | grep "^$region/" | cut -d'/' -f2 | nl
        
        read -p "Выберите номер города: " city_number
        timezone=$(timedatectl list-timezones | grep "^$region/" | sed -n "${city_number}p")
    fi
    
    if [ -n "$timezone" ]; then
        print_message "Установка часового пояса $timezone..."
        if timedatectl set-timezone "$timezone"; then
            print_success "Часовой пояс успешно установлен!"
            print_message "Текущее время: $(date)"
        else
            print_error "Ошибка при установке часового пояса"
        fi
    fi
}

setup_auto_restart() {
    print_logo
    print_message "Настройка автоматического перезапуска сервера..."
    
    # Показать текущие задачи перезапуска
    if crontab -l 2>/dev/null | grep -q "shutdown -r"; then
        print_message "Текущее расписание перезапуска:"
        crontab -l | grep "shutdown -r"
        echo ""
        read -p "Хотите изменить существующее расписание? (y/n): " change_schedule
        if [[ $change_schedule != "y" && $change_schedule != "Y" ]]; then
            return 0
        fi
    fi
    
    echo "Выберите периодичность перезапуска:"
    echo "1) Ежедневно"
    echo "2) Еженедельно"
    echo "3) Ежемесячно"
    echo "4) Отключить автоперезапуск"
    echo "0) Отмена"
    
    read -p "Ваш выбор [0-4]: " restart_choice
    
    case $restart_choice in
        1) # Ежедневно
            read -p "Введите время перезапуска (ЧЧ:ММ, например 03:00): " restart_time
            if [[ $restart_time =~ ^([0-1][0-9]|2[0-3]):([0-5][0-9])$ ]]; then
                hour=${restart_time%:*}
                minute=${restart_time#*:}
                (crontab -l 2>/dev/null | grep -v "shutdown -r"; echo "$minute $hour * * * /sbin/shutdown -r +5 'Плановый перезапуск через 5 минут'") | crontab -
                print_success "Ежедневный перезапуск настроен на $restart_time"
            else
                print_error "Неверный формат времени. Используйте формат ЧЧ:ММ (например, 02:00)"
                return 1
            fi
            ;;
            
        2) # Еженедельно
            echo "Выберите день недели:"
            echo "1) Понедельник"
            echo "2) Вторник"
            echo "3) Среда"
            echo "4) Четверг"
            echo "5) Пятница"
            echo "6) Суббота"
            echo "7) Воскресенье"
            read -p "Введите номер дня [1-7]: " day_number
            read -p "Введите время перезапуска (ЧЧ:ММ, например 03:00): " restart_time
            
            if [[ $restart_time =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]] && [[ $day_number =~ ^[1-7]$ ]]; then
                hour=${restart_time%:*}
                minute=${restart_time#*:}
                (crontab -l 2>/dev/null | grep -v "shutdown -r"; echo "$minute $hour * * $day_number /sbin/shutdown -r +5 'Плановый перезапуск через 5 минут'") | crontab -
                print_success "Еженедельный перезапуск настроен на $restart_time, день недели: $day_number"
            else
                print_error "Неверный формат времени или дня недели"
                return 1
            fi
            ;;
            
        3) # Ежемесячно
            read -p "Введите день месяца [1-31]: " month_day
            read -p "Введите время перезапуска (ЧЧ:ММ, например 03:00): " restart_time
            
            if [[ $restart_time =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]] && [[ $month_day =~ ^[1-9]|[12][0-9]|3[01]$ ]]; then
                hour=${restart_time%:*}
                minute=${restart_time#*:}
                (crontab -l 2>/dev/null | grep -v "shutdown -r"; echo "$minute $hour $month_day * * /sbin/shutdown -r +5 'Плановый перезапуск через 5 минут'") | crontab -
                print_success "Ежемесячный перезапуск настроен на $restart_time, день: $month_day"
            else
                print_error "Неверный формат времени или дня месяца"
                return 1
            fi
            ;;
            
        4) # Отключить автоперезапуск
            crontab -l 2>/dev/null | grep -v "shutdown -r" | crontab -
            print_success "Автоматический перезапуск отключен"
            ;;
            
        0) return 0 ;;
        
        *)
            print_error "Неверный выбор"
            return 1
            ;;
    esac
    
    # Показать текущее расписание
    echo ""
    print_message "Текущее расписание перезапуска:"
    crontab -l | grep "shutdown -r" || echo "Нет активных задач перезапуска"
}

# Показать главное меню CLI
show_menu() {
    print_logo
    echo -e "${WHITE}МЕНЮ НАСТРОЙКИ СЕРВЕРА:${NC}"
    echo ""
    echo -e "${YELLOW}== Основные настройки ==${NC}"
    echo -e "${CYAN}1)${NC} Первичная настройка системы"
    echo -e "${CYAN}2)${NC} Настройка часового пояса"
    echo -e "${CYAN}3)${NC} Настройка автоперезапуска сервера"
    echo ""
    echo -e "${YELLOW}== Веб и SSL ==${NC}"
    echo -e "${CYAN}4)${NC} Установка домена и демо-страницы с SSL"
    echo -e "${CYAN}5)${NC} Ручное обновление SSL сертификатов"
    echo -e "${CYAN}6)${NC} Копирование SSL сертификатов"
    echo ""
    echo -e "${YELLOW}== Безопасность ==${NC}"
    echo -e "${CYAN}7)${NC} Настройка файрвола UFW"
    echo ""
    echo -e "${YELLOW}== Приложения ==${NC}"
    echo -e "${CYAN}8)${NC} Установка Docker"
    echo -e "${CYAN}9)${NC} Установка 3X-UI"
    echo ""
    echo -e "${YELLOW}== Комплексная настройка ==${NC}"
    echo -e "${CYAN}10)${NC} Полная настройка системы"
    echo ""
    echo -e "${RED}0)${NC} Выход"
    echo ""
    echo -e "${YELLOW}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
    echo -e "┃  Сделано с ♥ от MrCerber Network           ┃"
    echo -e "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
    echo ""
    
    read -p "Выберите опцию [0-10]: " choice
    
    case $choice in
        # Основные настройки
        1) initial_setup ;;
        2) setup_timezone ;;
        3) setup_auto_restart ;;
        
        # Веб и SSL
        4) setup_domain ;;
        5) manual_ssl_renewal ;;
        6) copy_ssl_certificates ;;
        
        # Безопасность
        7) setup_ufw ;;
        
        # Приложения
        8) install_docker ;;
        9) install_3xui ;;
        
        # Комплексная настройка
        10) 
            print_message "Начинаем полную настройку системы..."
            initial_setup
            setup_timezone
            setup_domain
            install_docker
            install_3xui
            setup_ufw
            setup_auto_restart
            print_success "Полная настройка системы завершена!"
            ;;
        
        # Выход
        0) 
            clear
            echo -e "${CYAN}Спасибо за использование MrCerber Network VPS Setup!${NC}"
            echo ""
            exit 0 
            ;;
            
        *) print_error "Неверный выбор. Попробуйте снова." ;;
    esac
}

# Главная функция
main() {
    check_root
    while true; do
        show_menu
        echo ""
        read -p "Нажмите Enter для возврата в меню..."
    done
}

# Запуск скрипта
main