#!/bin/bash
set -euo pipefail

readonly TMP_DIR="/tmp"
readonly LOG_FILE="/tmp/chroot-build.log"

log_info() { echo "🚀 $*"; echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $*" >> "${LOG_FILE}"; }
log_ok()   { echo "✅ $*"; echo "$(date '+%Y-%m-%d %H:%M:%S') [OK] $*" >> "${LOG_FILE}"; }
log_warn() { echo "⚠️  $*"; echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] $*" >> "${LOG_FILE}"; }
log_err()  { echo "❌ $*" >&2; echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $*" >> "${LOG_FILE}"; }

# ==================== 网络诊断 ====================
check_network() {
    log_info "检查 chroot 网络环境..."

    if [[ -f /proc/net/dev ]]; then
        log_info "网络接口:"
        grep -E "eth|wlan|usb|enp" /proc/net/dev | sed 's/^/  /' || log_warn "无常见网络接口"
    fi

    if [[ -f /etc/resolv.conf ]]; then
        log_info "DNS 配置:"
        cat /etc/resolv.conf | sed 's/^/  /'
    else
        log_warn "/etc/resolv.conf 不存在！"
    fi

    if ping -c 1 -W 3 223.5.5.5 >/dev/null 2>&1; then
        log_ok "网络连通（IP层）"
    else
        log_warn "IP层无法连通宿主机网络"
    fi

    if ping -c 1 -W 3 mirrors.aliyun.com >/dev/null 2>&1; then
        log_ok "DNS 解析正常"
    else
        log_warn "DNS 解析失败，将使用备用方案"
        setup_dns
    fi
}

setup_dns() {
    log_info "配置备用 DNS..."
    cat > /etc/resolv.conf << 'EOF'
nameserver 223.5.5.5
nameserver 119.29.29.29
nameserver 8.8.8.8
EOF
    log_ok "DNS 已配置"
}

# ==================== 权限修复 ====================
fix_tmp_permissions() {
    log_info "修复 /tmp 权限..."
    chmod 1777 /tmp
    if ! touch /tmp/.apt-test 2>/dev/null; then
        log_err "/tmp 不可写！"
        exit 1
    fi
    rm -f /tmp/.apt-test
    log_ok "/tmp 权限正常"
}

# ==================== 包管理 ====================
install_package() {
    log_info "更新软件源..."

    # 确保软件源配置正确
    if [[ ! -f /etc/apt/sources.list ]] || ! grep -q "^deb" /etc/apt/sources.list; then
        log_warn "软件源配置缺失，重新配置..."
        cat > /etc/apt/sources.list << 'EOF'
deb http://mirrors.aliyun.com/debian trixie main contrib non-free non-free-firmware
deb http://mirrors.aliyun.com/debian trixie-updates main contrib non-free non-free-firmware
deb http://mirrors.aliyun.com/debian-security trixie-security main contrib non-free non-free-firmware
EOF
    fi

    if ! apt-get update; then
        log_warn "apt update 失败，尝试修复网络..."
        setup_dns
        apt-get update || {
            log_err "apt update 仍然失败"
            cat /etc/apt/sources.list | sed 's/^/  /'
            exit 1
        }
    fi

    log_info "安装本地 deb 包..."
    if ls "${TMP_DIR}"/*.deb >/dev/null 2>&1; then
        # 先安装基础包（不依赖 openstick-utils 的）
        dpkg -i "${TMP_DIR}"/firmware-*.deb "${TMP_DIR}"/libqrtr*.deb "${TMP_DIR}"/libssl*.deb "${TMP_DIR}"/linux-*.deb "${TMP_DIR}"/qrtr-tools*.deb "${TMP_DIR}"/rmtfs*.deb 2>/dev/null || true
    else
        log_warn "未找到本地 deb 包"
    fi

    log_info "安装核心依赖..."
    apt-get install -y --no-install-recommends \
        coreutils \
        network-manager \
        modemmanager \
        bc \
        bsdmainutils \
        gawk

    log_info "修复依赖..."
    apt-get --fix-broken install -y

    log_info "安装 QMI 工具..."
    apt-get install -y --no-install-recommends libqmi-utils

    log_info "安装 iptables-persistent..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends iptables-persistent

    log_info "安装 dnsmasq..."
    apt-get install -y --no-install-recommends dnsmasq-base

    log_info "安装 openstick-utils（如果存在）..."
    if ls "${TMP_DIR}"/openstick-utils*.deb >/dev/null 2>&1; then
        dpkg -i "${TMP_DIR}"/openstick-utils*.deb || true
        apt-get --fix-broken install -y
    fi

    log_ok "包安装完成"
}

remove_package() {
    log_info "移除冲突包..."
    local pkgs
    pkgs=$(dpkg -l 2>/dev/null | grep -E "meson|linux-image" | awk '{print $2}' || true)

    if [[ -n "${pkgs}" ]]; then
        echo "${pkgs}" | xargs -r dpkg -P
        log_ok "已移除: ${pkgs}"
    else
        log_info "无冲突包需要移除"
    fi
}

set_language() {
    log_info "配置中文环境..."

    if ! command -v locale-gen >/dev/null 2>&1; then
        apt-get install -y --no-install-recommends locales
    fi

    # 修复1: 同时生成 en_US.UTF-8 和 zh_CN.UTF-8，确保两者都存在
    sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen 2>/dev/null || true
    sed -i 's/^# *zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen 2>/dev/null || true
    sed -i 's/^# *zh_CN GB2312/zh_CN GB2312/' /etc/locale.gen 2>/dev/null || true

    locale-gen

    # 修复2: 清除可能干扰的环境变量，避免 update-locale 读取到宿主机的设置
    unset LANGUAGE
    unset LC_ALL
    unset LC_MESSAGES
    unset LANG

    # 修复3: 使用 --reset 先清空，再统一设置，避免混合 locale 导致的冲突
    update-locale --reset LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8 LANGUAGE=zh_CN:zh

    # 修复4: 显式导出，确保当前 shell 会话也生效
    export LANG=zh_CN.UTF-8
    export LC_ALL=zh_CN.UTF-8
    export LANGUAGE=zh_CN:zh

    if command -v fc-cache >/dev/null 2>&1; then
        fc-cache -fv
    fi

    log_ok "语言配置完成"
}

common_set() {
    log_info "应用系统配置..."

    rm -f /usr/sbin/openstick-startup-diagnose.sh
    rm -f /usr/lib/systemd/system/openstick-startup-diagnose.service
    rm -f /usr/lib/systemd/system/openstick-startup-diagnose.timer

    local files=(
        "${TMP_DIR}/mobian-setup-usb-network:/usr/sbin/mobian-setup-usb-network"
        "${TMP_DIR}/mobian-setup-usb-network.service:/usr/lib/systemd/system/mobian-setup-usb-network.service"
        "${TMP_DIR}/openstick-expanddisk-startup.sh:/usr/sbin/openstick-expanddisk-startup.sh"
        "${TMP_DIR}/rules.v4:/etc/iptables/rules.v4"
    )

    for pair in "${files[@]}"; do
        local src="${pair%%:*}"
        local dst="${pair##*:}"
        if [[ -f "${src}" ]]; then
            cp "${src}" "${dst}"
            chmod +x "${dst}" 2>/dev/null || true
        else
            log_warn "源文件不存在: ${src}"
        fi
    done

    touch /etc/fstab
    cat > /etc/fstab << 'EOF'
LABEL=aarch64 / btrfs defaults,noatime,compress=zstd,commit=30 0 0
EOF

    if [[ -f /etc/rc.local ]]; then
        sed -i '13i\nmcli c u USB' /etc/rc.local 2>/dev/null || true
        sed -i '1s/-e//' /etc/rc.local
    fi

    if [[ -f /usr/lib/systemd/system/rc-local.service ]]; then
        sed -i 's/forking/idle/g' /usr/lib/systemd/system/rc-local.service
    fi

    if [[ -f /etc/armbian-release ]]; then
        sed -i "s/'Odroid N2'/MSM8916/g" /etc/armbian-release
    fi

    if [[ -f /etc/default/armbian-zram-config ]]; then
        sed -i "s/# ZRAM_PERCENTAGE=50/ZRAM_PERCENTAGE=300/g" /etc/default/armbian-zram-config
        sed -i "s/# MEM_LIMIT_PERCENTAGE=50/MEM_LIMIT_PERCENTAGE=300/g" /etc/default/armbian-zram-config
    fi

    if [[ -f /usr/sbin/openstick-sim-changer.sh ]]; then
        sed -i '21 s/$sim/sim:sel/' /usr/sbin/openstick-sim-changer.sh
    fi

    rm -f /etc/localtime
    ln -sf /usr/share/zoneinfo/Asia/Chongqing /etc/localtime

    log_ok "系统配置完成"
}

clean_file() {
    log_info "清理 /boot..."
    rm -rf /boot
    mkdir -p /boot
    log_ok "/boot 已重建"
}

enable_motd() {
    if [[ -d /etc/update-motd.d ]]; then
        chmod +x /etc/update-motd.d/* 2>/dev/null || true
        log_ok "MOTD 已启用"
    fi
}

clean_apt_lists() {
    log_info "清理 APT 缓存..."
    rm -rf /var/lib/apt/lists/*
    apt-get clean all
    log_ok "缓存已清理"
}

# ==================== 主流程 ====================
main() {
    log_info "开始 chroot 构建..."

    check_network
    fix_tmp_permissions
    remove_package
    clean_file
    install_package

    log_info "设置 iptables 后端..."
    update-alternatives --set iptables /usr/sbin/iptables-legacy || log_warn "iptables 设置失败"

    set_language
    common_set
    enable_motd
    clean_apt_lists

    log_ok "构建完成！"
}

main "$@"