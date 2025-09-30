#!/bin/bash

# Скрипт управления MiroTalk
# Использование: ./manage_mirotalk.sh [start|stop|restart|status|logs|update|backup|restore]

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функции для вывода сообщений
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Переменные
MIROTALK_DIR="/opt/mirotalk"
BACKUP_DIR="/opt/mirotalk/backups"

# Проверка прав root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Этот скрипт должен быть запущен с правами root (sudo)"
        exit 1
    fi
}

# Проверка существования директории MiroTalk
check_mirotalk_dir() {
    if [[ ! -d "$MIROTALK_DIR" ]]; then
        log_error "Директория MiroTalk не найдена: $MIROTALK_DIR"
        log_info "Сначала запустите install_mirotalk.sh"
        exit 1
    fi
}

# Переход в директорию MiroTalk
cd_to_mirotalk() {
    cd "$MIROTALK_DIR"
}

# Функция запуска сервисов
start_services() {
    log_info "Запуск сервисов MiroTalk..."
    cd_to_mirotalk
    docker compose up -d
    log_success "Сервисы запущены"
}

# Функция остановки сервисов
stop_services() {
    log_info "Остановка сервисов MiroTalk..."
    cd_to_mirotalk
    docker compose down
    log_success "Сервисы остановлены"
}

# Функция перезапуска сервисов
restart_services() {
    log_info "Перезапуск сервисов MiroTalk..."
    cd_to_mirotalk
    docker compose restart
    log_success "Сервисы перезапущены"
}

# Функция проверки статуса
show_status() {
    log_info "Статус сервисов MiroTalk:"
    cd_to_mirotalk
    docker compose ps
    echo ""
    log_info "Использование ресурсов:"
    docker stats --no-stream
}

# Функция показа логов
show_logs() {
    log_info "Логи сервисов MiroTalk (Ctrl+C для выхода):"
    cd_to_mirotalk
    docker compose logs -f
}

# Функция обновления
update_mirotalk() {
    log_info "Обновление MiroTalk..."
    cd_to_mirotalk
    
    # Создание бэкапа перед обновлением
    create_backup "pre_update_$(date +%Y%m%d_%H%M%S)"
    
    # Остановка сервисов
    docker compose down
    
    # Обновление кода
    if [[ -d "mirotalk" ]]; then
        cd mirotalk
        git pull origin master
        cd ..
    else
        log_error "Директория mirotalk не найдена"
        exit 1
    fi
    
    # Пересборка и запуск
    docker compose build --no-cache
    docker compose up -d
    
    log_success "MiroTalk обновлен"
}

# Функция создания бэкапа
create_backup() {
    local backup_name="${1:-backup_$(date +%Y%m%d_%H%M%S)}"
    log_info "Создание бэкапа: $backup_name"
    
    mkdir -p "$BACKUP_DIR"
    cd_to_mirotalk
    
    # Создание архива с конфигурацией и данными
    tar -czf "$BACKUP_DIR/$backup_name.tar.gz" \
        --exclude="mirotalk/node_modules" \
        --exclude="mirotalk/.git" \
        --exclude="*.log" \
        --exclude="backups" \
        .
    
    # Сохранение списка Docker образов
    docker images > "$BACKUP_DIR/$backup_name.docker_images.txt"
    
    log_success "Бэкап создан: $BACKUP_DIR/$backup_name.tar.gz"
}

# Функция восстановления из бэкапа
restore_backup() {
    local backup_name="$1"
    
    if [[ -z "$backup_name" ]]; then
        log_info "Доступные бэкапы:"
        ls -la "$BACKUP_DIR"/*.tar.gz 2>/dev/null || log_warning "Бэкапы не найдены"
        echo ""
        log_info "Использование: $0 restore <имя_бэкапа>"
        return 1
    fi
    
    local backup_file="$BACKUP_DIR/$backup_name.tar.gz"
    
    if [[ ! -f "$backup_file" ]]; then
        log_error "Бэкап не найден: $backup_file"
        return 1
    fi
    
    log_warning "Восстановление из бэкапа: $backup_name"
    log_warning "Это остановит текущие сервисы и восстановит данные!"
    read -p "Продолжить? (y/N): " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Восстановление отменено"
        return 1
    fi
    
    # Остановка сервисов
    stop_services
    
    # Восстановление из архива
    cd_to_mirotalk
    tar -xzf "$backup_file"
    
    # Запуск сервисов
    start_services
    
    log_success "Восстановление завершено"
}

# Функция очистки
cleanup() {
    log_info "Очистка системы..."
    
    # Остановка и удаление контейнеров
    cd_to_mirotalk
    docker compose down -v
    
    # Удаление неиспользуемых образов
    docker image prune -f
    
    # Удаление неиспользуемых томов
    docker volume prune -f
    
    # Очистка старых логов
    find /var/log -name "*.log" -type f -mtime +30 -delete 2>/dev/null || true
    
    log_success "Очистка завершена"
}

# Функция мониторинга
monitor() {
    log_info "Мониторинг сервисов MiroTalk (Ctrl+C для выхода):"
    
    while true; do
        clear
        echo "=== MiroTalk Status Monitor ==="
        echo "Время: $(date)"
        echo ""
        
        cd_to_mirotalk
        docker compose ps
        echo ""
        
        echo "=== Использование ресурсов ==="
        docker stats --no-stream
        echo ""
        
        echo "=== Последние логи ==="
        docker compose logs --tail=10
        echo ""
        
        echo "Обновление через 30 секунд..."
        sleep 30
    done
}

# Функция показа справки
show_help() {
    echo "Скрипт управления MiroTalk"
    echo ""
    echo "Использование: $0 [команда]"
    echo ""
    echo "Команды:"
    echo "  start     - Запустить сервисы"
    echo "  stop      - Остановить сервисы"
    echo "  restart   - Перезапустить сервисы"
    echo "  status    - Показать статус сервисов"
    echo "  logs      - Показать логи (следить)"
    echo "  update    - Обновить MiroTalk"
    echo "  backup    - Создать бэкап"
    echo "  restore   - Восстановить из бэкапа"
    echo "  cleanup   - Очистить систему"
    echo "  monitor   - Мониторинг в реальном времени"
    echo "  help      - Показать эту справку"
    echo ""
    echo "Примеры:"
    echo "  $0 start"
    echo "  $0 backup my_backup"
    echo "  $0 restore backup_20231201_120000"
}

# Основная логика
main() {
    local command="${1:-help}"
    
    case "$command" in
        start)
            check_root
            check_mirotalk_dir
            start_services
            ;;
        stop)
            check_root
            check_mirotalk_dir
            stop_services
            ;;
        restart)
            check_root
            check_mirotalk_dir
            restart_services
            ;;
        status)
            check_mirotalk_dir
            show_status
            ;;
        logs)
            check_mirotalk_dir
            show_logs
            ;;
        update)
            check_root
            check_mirotalk_dir
            update_mirotalk
            ;;
        backup)
            check_root
            check_mirotalk_dir
            create_backup "$2"
            ;;
        restore)
            check_root
            check_mirotalk_dir
            restore_backup "$2"
            ;;
        cleanup)
            check_root
            check_mirotalk_dir
            cleanup
            ;;
        monitor)
            check_mirotalk_dir
            monitor
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "Неизвестная команда: $command"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

# Запуск основной функции
main "$@"

