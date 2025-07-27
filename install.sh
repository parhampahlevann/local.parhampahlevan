#!/bin/bash

# تابع نمایش پیام با رنگ
function colored_msg() {
    local color=$1
    local message=$2
    case $color in
        red) echo -e "\033[31m$message\033[0m" ;;
        green) echo -e "\033[32m$message\033[0m" ;;
        yellow) echo -e "\033[33m$message\033[0m" ;;
        blue) echo -e "\033[34m$message\033[0m" ;;
        *) echo "$message" ;;
    esac
}

# تابع بررسی ریشه بودن کاربر
function check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        colored_msg red "این اسکریپت باید با دسترسی root اجرا شود."
        exit 1
    fi
}

# تابع بررسی سیستم عامل
function check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    elif type lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
        VER=$(lsb_release -sr)
    else
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
        VER=$(uname -r)
    fi

    if [[ "$OS" != "ubuntu" && "$OS" != "debian" && "$OS" != "centos" && "$OS" != "fedora" ]]; then
        colored_msg red "این اسکریپت فقط روی سیستم‌های مبتنی بر Debian/Ubuntu و RHEL/CentOS/Fedora پشتیبانی می‌شود."
        exit 1
    fi
}

# تابع نصب بسته‌های لازم
function install_dependencies() {
    colored_msg blue "در حال بررسی و نصب بسته‌های لازم..."
    
    if [ -f /etc/debian_version ]; then
        apt-get update
        apt-get install -y iproute2 net-tools sed grep iputils-ping
    elif [ -f /etc/redhat-release ]; then
        yum install -y iproute net-tools sed grep iputils
    fi
}

# تابع ایجاد تونل
function create_tunnel() {
    local location=$1
    local iran_ipv4=$2
    local foreign_ipv4=$3
    
    # پیشوند IPv6 مشترک
    local ipv6_prefix="fdbd:1b5d:0aa8"
    
    if [ "$location" == "iran" ]; then
        local local_ipv6="${ipv6_prefix}::1/64"
        local remote_ipv6="${ipv6_prefix}::2"
        local local_ipv4=$iran_ipv4
        local remote_ipv4=$foreign_ipv4
    else
        local local_ipv6="${ipv6_prefix}::2/64"
        local remote_ipv6="${ipv6_prefix}::1"
        local local_ipv4=$foreign_ipv4
        local remote_ipv4=$iran_ipv4
    fi
    
    # ایجاد رابط تونل
    ip tunnel add ipv6tun mode sit remote $remote_ipv4 local $local_ipv4 ttl 255
    ip link set ipv6tun up
    ip addr add $local_ipv6 dev ipv6tun
    ip route add ::/0 dev ipv6tun
    
    # فعال کردن IPv6
    echo 1 > /proc/sys/net/ipv6/conf/all/forwarding
    echo 1 > /proc/sys/net/ipv6/conf/default/forwarding
    echo 1 > /proc/sys/net/ipv6/conf/ipv6tun/forwarding
    
    colored_msg green "تونل IPv6 با موفقیت ایجاد شد!"
    echo ""
    colored_msg yellow "اطلاعات تونل:"
    echo "آدرس IPv6 محلی: $local_ipv6"
    echo "آدرس IPv6 ریموت: $remote_ipv6"
    echo ""
    colored_msg yellow "برای تست ارتباط، دستور زیر را در سرور مقابل اجرا کنید:"
    colored_msg blue "ping6 $remote_ipv6"
}

# تابع اصلی
function main() {
    clear
    colored_msg blue "===================================="
    colored_msg blue "نصب کننده تونل IPv6 بین سرور ایران و خارج"
    colored_msg blue "===================================="
    echo ""
    
    check_root
    check_os
    install_dependencies
    
    # انتخاب موقعیت سرور
    PS3="لطفاً موقعیت این سرور را انتخاب کنید: "
    options=("ایران" "خارج")
    select opt in "${options[@]}"
    do
        case $opt in
            "ایران")
                location="iran"
                break
                ;;
            "خارج")
                location="foreign"
                break
                ;;
            *) echo "گزینه نامعتبر";;
        esac
    done
    
    echo ""
    colored_msg yellow "لطفاً اطلاعات مورد نیاز را وارد کنید:"
    read -p "آدرس IPv4 سرور ایران: " iran_ipv4
    read -p "آدرس IPv4 سرور خارج: " foreign_ipv4
    
    echo ""
    colored_msg blue "در حال ایجاد تونل IPv6..."
    create_tunnel "$location" "$iran_ipv4" "$foreign_ipv4"
}

# اجرای تابع اصلی
main
