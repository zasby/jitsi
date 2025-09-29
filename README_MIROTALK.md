# MiroTalk - Развертывание на сервере

Полная настройка MiroTalk для групповых P2P видеозвонков на домене `connect.mooz.pro` с использованием Docker.

## 🚀 Быстрый старт

### Автоматическая установка

```bash
# Скачайте скрипт установки
wget https://raw.githubusercontent.com/your-repo/install_mirotalk.sh
chmod +x install_mirotalk.sh

# Запустите установку (требуются права root)
sudo ./install_mirotalk.sh
```

### Ручная установка

1. **Подготовка сервера**
```bash
# Обновление системы
sudo apt update && sudo apt upgrade -y

# Установка необходимых пакетов
sudo apt install -y git curl wget docker.io docker-compose-plugin
```

2. **Клонирование проекта**
```bash
git clone https://github.com/miroslavpejic85/mirotalk.git
cd mirotalk
```

3. **Настройка конфигурации**
```bash
cp .env.template .env
nano .env  # Отредактируйте DOMAIN=connect.mooz.pro
```

4. **Запуск сервисов**
```bash
docker compose up -d
```

## 📁 Структура проекта

```
/opt/mirotalk/
├── docker-compose.yml          # Основная конфигурация Docker
├── .env                        # Переменные окружения
├── nginx/                      # Конфигурация Nginx
│   ├── nginx.conf
│   └── conf.d/mirotalk.conf
├── ssl/                        # SSL сертификаты
├── certbot/                    # Let's Encrypt сертификаты
├── logs/                       # Логи приложения
├── data/                       # Данные приложения
└── backups/                    # Резервные копии
```

## 🔧 Управление сервисами

### Основные команды

```bash
# Запуск сервисов
./manage_mirotalk.sh start

# Остановка сервисов
./manage_mirotalk.sh stop

# Перезапуск сервисов
./manage_mirotalk.sh restart

# Проверка статуса
./manage_mirotalk.sh status

# Просмотр логов
./manage_mirotalk.sh logs

# Обновление MiroTalk
./manage_mirotalk.sh update

# Создание бэкапа
./manage_mirotalk.sh backup my_backup

# Восстановление из бэкапа
./manage_mirotalk.sh restore backup_20231201_120000
```

### Systemd сервис

```bash
# Управление через systemd
sudo systemctl start mirotalk
sudo systemctl stop mirotalk
sudo systemctl restart mirotalk
sudo systemctl status mirotalk
```

## 🔒 SSL сертификаты

### Автоматическое получение

Скрипт автоматически получает SSL сертификаты через Let's Encrypt:

```bash
# Ручное обновление сертификатов
cd /opt/mirotalk
docker compose run --rm certbot renew
docker compose exec nginx nginx -s reload
```

### Автоматическое обновление

Настроена cron задача для автоматического обновления сертификатов каждые 12 часов.

## 🌐 TURN сервер (опционально)

Для улучшения P2P соединений через NAT рекомендуется настроить TURN сервер:

```bash
# Установка и настройка TURN сервера
sudo ./setup_turn_server.sh
```

### Конфигурация TURN

После установки TURN сервера обновите файл `.env`:

```env
TURN_SERVERS=turn:connect.mooz.pro:3478:username:password
```

## 📊 Мониторинг

### Статус сервисов

```bash
# Проверка статуса всех контейнеров
docker compose ps

# Использование ресурсов
docker stats

# Логи в реальном времени
docker compose logs -f

# Мониторинг TURN сервера
turn-monitor.sh
```

### Логи

- **MiroTalk**: `/opt/mirotalk/logs/`
- **Nginx**: `/var/log/nginx/`
- **TURN сервер**: `/var/log/turnserver.log`

## 🔧 Конфигурация

### Основные параметры (.env)

```env
# Основные настройки
DOMAIN=connect.mooz.pro
PORT=3000
NODE_ENV=production

# Настройки P2P
P2P_ENABLED=true
STUN_SERVERS=stun:stun.l.google.com:19302
TURN_SERVERS=turn:connect.mooz.pro:3478:user:pass

# Настройки комнат
MAX_PARTICIPANTS=10
ROOM_NAME_LENGTH=10
ROOM_EXPIRY_TIME=24

# Настройки безопасности
CORS_ORIGIN=*
RATE_LIMIT=true
```

### Nginx конфигурация

Файл: `/opt/mirotalk/nginx/conf.d/mirotalk.conf`

Основные настройки:
- Автоматический редирект HTTP → HTTPS
- WebSocket поддержка
- SSL/TLS конфигурация
- Кэширование статических файлов
- CORS headers для API

## 🛡️ Безопасность

### Firewall

Автоматически настраиваются правила для:
- SSH (22)
- HTTP (80)
- HTTPS (443)
- TURN UDP (3478)
- TURN TLS (5349)

### SSL/TLS

- TLS 1.2 и 1.3
- Современные cipher suites
- HSTS headers
- Автоматическое обновление сертификатов

## 🔄 Обновления

### Автоматическое обновление

```bash
# Обновление MiroTalk
./manage_mirotalk.sh update
```

### Ручное обновление

```bash
cd /opt/mirotalk/mirotalk
git pull origin main
docker compose build --no-cache
docker compose up -d
```

## 🆘 Устранение неполадок

### Проблемы с SSL

```bash
# Проверка сертификатов
openssl x509 -in /etc/letsencrypt/live/connect.mooz.pro/fullchain.pem -text -noout

# Тест SSL соединения
openssl s_client -connect connect.mooz.pro:443 -servername connect.mooz.pro
```

### Проблемы с P2P

```bash
# Проверка STUN серверов
nmap -sU -p 3478 connect.mooz.pro

# Тест TURN сервера
turnutils_stunclient connect.mooz.pro
```

### Логи для диагностики

```bash
# Все логи Docker
docker compose logs

# Логи конкретного сервиса
docker compose logs mirotalk
docker compose logs nginx

# Системные логи
journalctl -u docker -f
```

## 📞 Поддержка

### Полезные команды

```bash
# Перезапуск всех сервисов
./manage_mirotalk.sh restart

# Очистка системы
./manage_mirotalk.sh cleanup

# Мониторинг в реальном времени
./manage_mirotalk.sh monitor

# Создание бэкапа перед изменениями
./manage_mirotalk.sh backup pre_update
```

### Контакты

- **Домен**: https://connect.mooz.pro
- **Документация MiroTalk**: https://docs.mirotalk.com
- **GitHub**: https://github.com/miroslavpejic85/mirotalk

## 📝 Лицензия

Этот проект использует MiroTalk под лицензией MIT. См. [LICENSE](LICENSE) для подробностей.

---

**Примечание**: Убедитесь, что домен `connect.mooz.pro` правильно настроен в DNS и указывает на IP-адрес вашего сервера перед запуском установки.
