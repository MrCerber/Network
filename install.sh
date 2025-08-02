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

# Установка домена и демо-страницы с улучшенной конфигурацией
setup_domain() {
    print_logo
    print_message "Настройка домена и демо-страницы с расширенной конфигурацией..."
    
    # Установка необходимых пакетов
    apt install -y nginx certbot python3-certbot-nginx ssl-cert
    
    # Запрос домена
    read -p "Введите ваш домен (например, example.com): " domain_name
    if [ -z "$domain_name" ]; then
        print_error "Домен не указан. Отмена настройки."
        return 1
    fi
    
    # Создание оптимизированной конфигурации Nginx
    print_message "Создание оптимизированной конфигурации Nginx для домена $domain_name..."
    
    # Создание директории для логов
    mkdir -p /var/log/nginx/$domain_name

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

    # Настройка оптимизированного Nginx для домена
    cat > /etc/nginx/sites-available/$domain_name << EOF
# Редирект с HTTP на HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name $domain_name www.$domain_name;
    
    # Логи
    access_log /var/log/nginx/$domain_name/access.log;
    error_log /var/log/nginx/$domain_name/error.log;
    
    # Редирект на HTTPS
    location / {
        return 301 https://$domain_name\$request_uri;
    }
    
    # Конфигурация для Let's Encrypt
    location ~ /.well-known/acme-challenge {
        root /var/www/letsencrypt;
        allow all;
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

    # Создание директории для Let's Encrypt
    mkdir -p /var/www/letsencrypt
    
    # Создание директории и демо-страницы с Tailwind CSS
    mkdir -p /var/www/$domain_name
    
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
    
    # Проверка конфигурации Nginx
    print_message "Проверка конфигурации Nginx..."
    nginx -t
    
    if [ $? -ne 0 ]; then
        print_error "Обнаружена ошибка в конфигурации Nginx. Пожалуйста, проверьте настройки."
        return 1
    fi
    
    # Активация конфигурации и перезапуск Nginx
    ln -sf /etc/nginx/sites-available/$domain_name /etc/nginx/sites-enabled/
    
    # Удаление конфигурации по умолчанию если существует
    if [ -f /etc/nginx/sites-enabled/default ]; then
        rm -f /etc/nginx/sites-enabled/default
    fi
    
    # Перезапуск Nginx
    systemctl restart nginx
    
    # Установка SSL сертификата через Certbot
    print_message "Установка SSL сертификата через Certbot..."
    
    # Создаем временную конфигурацию для первичного получения сертификата
    certbot --nginx -d $domain_name -d www.$domain_name --non-interactive --agree-tos --email admin@$domain_name
    
    if [ $? -ne 0 ]; then
        print_warning "Не удалось автоматически настроить SSL. Попробуйте вручную выполнить команду:"
        echo "sudo certbot --nginx -d $domain_name -d www.$domain_name"
    else
        print_success "SSL сертификат успешно установлен для $domain_name!"
        
        # Настройка автоматического обновления сертификатов
        print_message "Настройка автоматического обновления SSL сертификатов..."
        
        # Проверяем существование задачи в crontab
        if ! crontab -l | grep -q certbot; then
            (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook \"systemctl reload nginx\"") | crontab -
            print_success "Автоматическое обновление SSL настроено!"
        else
            print_message "Задача автообновления SSL уже существует в crontab."
        fi
    fi
    
    # Финальная перезагрузка Nginx
    systemctl restart nginx
    
    print_success "Домен $domain_name успешно настроен с оптимизированным Nginx и SSL сертификатом!"
    print_message "Ваш сайт доступен по адресу: https://$domain_name"
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

# Установка 3X-UI
install_3xui() {
    print_logo
    print_message "Установка 3X-UI..."
    
    # Установка с использованием официального скрипта
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
    
    print_success "3X-UI установлен. Вы можете управлять им через веб-интерфейс."
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

# Показать главное меню CLI
show_menu() {
    print_logo
    echo -e "${WHITE}МЕНЮ НАСТРОЙКИ СЕРВЕРА:${NC}"
    echo ""
    echo -e "${CYAN}1)${NC} Первичная настройка системы (обновления, утилиты, пользователь)"
    echo -e "${CYAN}2)${NC} Установка домена и демо-страницы с SSL"
    echo -e "${CYAN}3)${NC} Установка Docker"
    echo -e "${CYAN}4)${NC} Установка 3X-UI"
    echo -e "${CYAN}5)${NC} Настройка файрвола UFW"
    echo -e "${CYAN}6)${NC} Полная настройка (опции 1-5)"
    echo -e "${RED}0)${NC} Выход"
    echo ""
    echo -e "${YELLOW}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
    echo -e "┃  Сделано с ♥ от MrCerber Network           ┃"
    echo -e "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
    echo ""
    
    read -p "Выберите опцию [0-6]: " choice
    
    case $choice in
        1) initial_setup ;;
        2) setup_domain ;;
        3) install_docker ;;
        4) install_3xui ;;
        5) setup_ufw ;;
        6) 
           initial_setup
           setup_domain
           install_docker
           install_3xui
           setup_ufw
           ;;
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