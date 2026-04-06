#!/bin/bash
# =============================================================================
# GitHub Self-Hosted Runner - User Setup Script (RHEL/CentOS only)
# Usage: sudo bash setup_runner_user.sh <username> '<password>'
# Example: sudo bash setup_runner_user.sh github-runner 'MyStr0ng@Pass!23'
# NOTE: Always wrap the password in single quotes to avoid bash interpretation
#       of special characters like ! $ { } ~ [ ]
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Colors for output
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# -----------------------------------------------------------------------------
# 1. Validate arguments and root
# -----------------------------------------------------------------------------
if [[ $# -ne 2 ]]; then
    echo -e "Usage: $0 <username> '<password>'"
    echo -e "Example: $0 github-runner 'MyStr0ng@Pass!23'"
    echo -e ""
    echo -e "Password requirements:"
    echo -e "  - At least 14 characters"
    echo -e "  - At least one uppercase letter (A-Z)"
    echo -e "  - At least one lowercase letter (a-z)"
    echo -e "  - At least one digit (0-9)"
    echo -e "  - At least one special character (!@#\$%^&*...)"
    exit 1
fi

USERNAME="$1"
PASSWORD="$2"

if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root. Use: sudo bash $0 $USERNAME '<password>'"
fi

# -----------------------------------------------------------------------------
# 2. Password strength validation
# -----------------------------------------------------------------------------
log_info "Validating password strength..."

if [[ ${#PASSWORD} -lt 14 ]]; then
    log_error "Password must be at least 14 characters long (current: ${#PASSWORD})."
fi

if ! echo "$PASSWORD" | grep -q '[A-Z]'; then
    log_error "Password must contain at least one uppercase letter (A-Z)."
fi

if ! echo "$PASSWORD" | grep -q '[a-z]'; then
    log_error "Password must contain at least one lowercase letter (a-z)."
fi

if ! echo "$PASSWORD" | grep -q '[0-9]'; then
    log_error "Password must contain at least one digit (0-9)."
fi

if ! echo "$PASSWORD" | grep -qP '[^a-zA-Z0-9]'; then
    log_error "Password must contain at least one special character (!@#\$%^&*+-=[]{}|;:,.<>?)."
fi

log_success "Password meets all requirements."

log_info "Starting setup for runner user: '${USERNAME}'"
echo "=============================================="

# -----------------------------------------------------------------------------
# 3. Create the user (force clean if exists without home dir)
# -----------------------------------------------------------------------------
if id "$USERNAME" &>/dev/null; then
    HOME_DIR="/home/${USERNAME}"
    if [[ ! -d "$HOME_DIR" ]]; then
        log_warn "User '${USERNAME}' exists but has no home directory. Deleting and recreating..."
        userdel "$USERNAME" &>/dev/null || true
        useradd -m -s /bin/bash "$USERNAME"
        log_success "User '${USERNAME}' recreated with home directory."
    else
        log_warn "User '${USERNAME}' already exists with home directory. Skipping creation."
    fi
else
    useradd -m -s /bin/bash "$USERNAME"
    log_success "User '${USERNAME}' created."
fi

HOME_DIR="/home/${USERNAME}"

# -----------------------------------------------------------------------------
# 4. Set the password
# -----------------------------------------------------------------------------
echo "${USERNAME}:${PASSWORD}" | chpasswd
log_success "Password set for '${USERNAME}'."

# -----------------------------------------------------------------------------
# 5. Disable forced password expiry on first login
# -----------------------------------------------------------------------------
chage -d "$(date +%Y-%m-%d)" "$USERNAME"
chage -M -1 "$USERNAME"
log_success "Password expiry disabled for '${USERNAME}'."

log_info "Password aging info for '${USERNAME}':"
chage -l "$USERNAME" | sed 's/^/         /'

# -----------------------------------------------------------------------------
# 6. Remove from wheel group (no sudo)
# -----------------------------------------------------------------------------
if groups "$USERNAME" | grep -q '\bwheel\b'; then
    gpasswd -d "$USERNAME" wheel &>/dev/null
    log_success "Removed '${USERNAME}' from wheel group."
else
    log_success "'${USERNAME}' is not in wheel group. Good."
fi

# -----------------------------------------------------------------------------
# 7. Verify no sudo rights (using sudoers file directly — no password prompt)
# -----------------------------------------------------------------------------
if grep -q "^${USERNAME}" /etc/sudoers 2>/dev/null || \
   grep -rq "^${USERNAME}" /etc/sudoers.d/ 2>/dev/null; then
    log_warn "'${USERNAME}' has an entry in sudoers! Please review manually."
else
    log_success "'${USERNAME}' has no sudo rights. Confirmed."
fi

# -----------------------------------------------------------------------------
# 8. Set correct permissions on home directory
# -----------------------------------------------------------------------------
chmod 755 "$HOME_DIR"
log_success "Home directory permissions set to 755: ${HOME_DIR}"

# -----------------------------------------------------------------------------
# 9. Create the actions-runner directory
# -----------------------------------------------------------------------------
RUNNER_DIR="${HOME_DIR}/actions-runner"
if [[ ! -d "$RUNNER_DIR" ]]; then
    mkdir -p "$RUNNER_DIR"
    log_success "Created runner directory: ${RUNNER_DIR}"
else
    log_warn "Runner directory already exists: ${RUNNER_DIR}"
fi

# -----------------------------------------------------------------------------
# 10. Set ownership
# -----------------------------------------------------------------------------
chown -R "${USERNAME}:${USERNAME}" "$HOME_DIR"
log_success "Ownership set to '${USERNAME}' for: ${HOME_DIR}"

# -----------------------------------------------------------------------------
# 11. Apply correct SELinux context (fixes systemd 203/EXEC error on RHEL)
# -----------------------------------------------------------------------------
log_info "Applying SELinux context..."
if ! command -v semanage &>/dev/null; then
    log_warn "semanage not found. Installing policycoreutils-python-utils..."
    dnf install -y policycoreutils-python-utils &>/dev/null
    log_success "policycoreutils-python-utils installed."
fi

semanage fcontext -a -t bin_t "${RUNNER_DIR}(/.*)?" 2>/dev/null || \
semanage fcontext -m -t bin_t "${RUNNER_DIR}(/.*)?"
restorecon -Rv "$RUNNER_DIR" &>/dev/null
log_success "SELinux context set to 'bin_t' for: ${RUNNER_DIR}"

# -----------------------------------------------------------------------------
# 12. Final summary
# -----------------------------------------------------------------------------
echo ""
echo "=============================================="
log_success "Setup complete for user '${USERNAME}'!"
echo "=============================================="
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "  1. Switch to the runner user:"
echo "     sudo su - ${USERNAME}"
echo ""
echo "  2. Go to your GitHub repo:"
echo "     Settings → Actions → Runners → New self-hosted runner"
echo ""
echo "  3. Download and configure the runner inside ${RUNNER_DIR}"
echo ""
echo "  4. Install and start the service (as root):"
echo "     ./svc.sh install ${USERNAME}"
echo "     ./svc.sh start"
echo "     ./svc.sh status"
echo ""
echo -e "${YELLOW}REMINDER:${NC} Always wrap passwords in single quotes when passing as argument:"
echo "     sudo bash $0 ${USERNAME} '<your-password>'"
echo ""
