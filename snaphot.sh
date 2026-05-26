#!/bin/bash

# ==============================================================================
# SCRIPT      : lvm-manager.sh
# DESCRIPTION : Gestion automatisée de snapshots LVM (Création, Rotation, Rollback)
# AUTEUR      : ps81frt
# REPO GIT    : https://github.com/ps81frt/lvm-manager
# ==============================================================================
# PRÉREQUIS CRITIQUES (À VÉRIFIER AVANT LE PREMIER LANCEMENT) :
#
#   1. Votre Linux doit être installé sur du LVM (ex: Ubuntu Option LVM cochée).
#   2. ESPACE LIBRE DANS LE VG IMPÉRATIF :
#      Par défaut, Ubuntu alloue 100% de l'espace disque au volume racine (/).
#      Or, LVM a besoin d'espace NON ALLOUÉ dans le Volume Group pour créer un
#      snapshot (ici 5 Go min.).
#
#      --> LANCEZ CETTE COMMANDE : sudo vgs
#      --> VÉRIFIEZ LA COLONNE 'VFree'. Si elle est à 0 (ou < 5g), le script plantera.
#
#      --> COMMANDES POUR LIBÉRER COMPORTEMENTALEMENT 10 GO DE SYSTÈME DE FICHIERS :
#          A) Si vous réduisez le ROOT (/) -> IMPÉRATIF depuis une clé USB Live :
#             sudo lvreduce -r -L -10G /dev/NOM_DE_VOTRE_VG/ubuntu-lv
#
#          B) Si vous réduisez le HOME (/home) -> Depuis votre OS (hors session graphique) :
#             sudo umount /home
#             sudo lvreduce -r -L -10G /dev/NOM_DE_VOTRE_VG/home-lv
# ==============================================================================
# PARAMÈTRES DE COMMANDE (USAGE) :
#   Syntaxe : ./lvm-manager.sh <ACTION> [TARGET]
#
#   <ACTION> (Obligatoire) :
#     create   : Crée un snapshot du volume cible + exécute la rotation (cleanup).
#     list     : Liste brute des snapshots de la cible (tri chronologique).
#     cleanup  : Force la purge des snapshots obsolètes selon la limite KEEP.
#     rollback : Fusionne (merge) le dernier snapshot valide. Bloquant si non-TTY.
#
#   [TARGET] (Optionnel) :
#     Point de montage (ex: /var/lib/docker) ou chemin du device (ex: /dev/vg0/lv_data).
#     Valeur par défaut si omis : / (Racine du système).
# ==============================================================================
# CONFIGURATION PAR DÉFAUT :
#   SNAP_PREFIX="snap"              # Identifiant de filtrage des snapshots
#   KEEP=3                          # Nombre maximal de snapshots conservés
#   SNAPSHOT_SIZE_DEFAULT="5G"      # Allocation d'espace (LVM classique uniquement)
#   LOCKFILE="/tmp/lvm-snap.lock"   # Mutex de sérialisation via 'flock'
# ==============================================================================

set -euo pipefail

SNAP_PREFIX="snap"
KEEP=3
SNAPSHOT_SIZE_DEFAULT="5G"
LOCKFILE="/tmp/lvm-snap.lock"

TARGET_DEV=""
VG=""
LV=""
IS_ROOT_TARGET=0

exec 9>"$LOCKFILE"
if ! flock -n 9; then
    echo "[lvm-snapshot] [ERROR] Another instance is running. Aborting." >&2
    exit 1
fi

log() {
    echo "[lvm-snapshot] $1"
}

resolve_target() {
    local input="${1:-/}"
    local resolved_input root_canonical target_canonical

    if [[ -d "$input" ]]; then
        resolved_input=$(findmnt -no SOURCE "$input")
    else
        resolved_input="$input"
    fi

    if [[ -z "$resolved_input" ]] || ! lvs "$resolved_input" &>/dev/null; then
        echo "[ERROR] Invalid target volume or mountpoint: $input" >&2
        exit 1
    fi

    target_canonical=$(readlink -f "$resolved_input")
    root_canonical=$(readlink -f "$(findmnt -no SOURCE /)")

    TARGET_DEV="$target_canonical"
    VG=$(lvs --noheadings -o vg_name "$TARGET_DEV" | awk '{print $1}')
    LV=$(lvs --noheadings -o lv_name "$TARGET_DEV" | awk '{print $1}')

    if [[ "$TARGET_DEV" == "$root_canonical" ]]; then
        IS_ROOT_TARGET=1
    else
        IS_ROOT_TARGET=0
    fi
}

timestamp() {
    date +%Y%m%d-%H%M%S
}

create_snapshot() {
    local snap_name segtype
    local -a snap_args=()

    segtype=$(lvs --noheadings -o segtype "$TARGET_DEV" | awk '{print $1}')

    if [[ "$segtype" =~ thin ]]; then
        log "Context: Thin provisioning detected for $VG/$LV."
    else
        snap_args+=("-L" "$SNAPSHOT_SIZE_DEFAULT")
        log "Context: Classic LVM detected. Size: $SNAPSHOT_SIZE_DEFAULT"
    fi

    snap_name="${SNAP_PREFIX}-${LV}-$(timestamp)"
    log "Creating snapshot: $snap_name"

    lvcreate "${snap_args[@]}" -s -n "$snap_name" "$TARGET_DEV"
    log "Snapshot created successfully."
}

list_snapshots() {
    lvs --noheadings -o lv_full_name --sort lv_time \
        -S "vg_name=${VG} && origin=${LV} && lv_name=~^${SNAP_PREFIX}-" | awk '{print $1}'
}

cleanup_snapshots() {
    local -a snaps
    local count delete_count i

    log "Cleaning old snapshots for $VG/$LV (KEEP=$KEEP)"

    mapfile -t snaps < <(list_snapshots)
    count=${#snaps[@]}

    if ((count <= KEEP)); then
        log "No cleanup needed ($count snapshots found)."
        return
    fi

    delete_count=$((count - KEEP))
    for ((i = 0; i < delete_count; i++)); do
        log "Removing stale snapshot: ${snaps[$i]}"
        lvremove -y "${snaps[$i]}"
    done
    log "Cleanup done."
}

rollback_snapshot() {
    local snap confirm

    snap=$(list_snapshots | tail -n 1)

    if [[ -z "$snap" ]]; then
        log "No snapshot found for volume $VG/$LV"
        exit 1
    fi

    echo "==========================================================" >&2
    echo "CRITICAL WARNING: ROLLBACK OPERATION" >&2
    echo "Target volume : $VG/$LV" >&2
    echo "Snapshot      : $snap" >&2
    echo "----------------------------------------------------------" >&2

    if ((IS_ROOT_TARGET == 1)); then
        echo "WARNING: This is the active ROOT filesystem." >&2
        echo "The system will automatically queue a live merge." >&2
        echo "You MUST reboot immediately after this command." >&2
    else
        echo "Notice: This is a data volume. If it is currently mounted," >&2
        echo "unmount it or restart services using it to apply changes safely." >&2
    fi
    echo "==========================================================" >&2

    if [[ ! -t 0 ]]; then
        echo "[ERROR] Non-interactive environment detected. Cannot prompt for rollback confirmation." >&2
        exit 1
    fi

    read -p "Type 'YES' to execute rollback: " -r confirm
    if [[ "$confirm" != "YES" ]]; then
        log "Rollback aborted."
        exit 0
    fi

    log "Merging: $snap"
    lvconvert --merge "$snap"

    if ((IS_ROOT_TARGET == 1)); then
        log "SUCCESS: Merge scheduled. REBOOT NOW."
    else
        log "SUCCESS: Merge initiated. Remount the volume to complete."
    fi
}

ACTION="${1:-}"
TARGET="${2:-/}"

resolve_target "$TARGET"

case "$ACTION" in
create)
    create_snapshot
    cleanup_snapshots
    ;;
list)
    list_snapshots
    ;;
cleanup)
    cleanup_snapshots
    ;;
rollback)
    rollback_snapshot
    ;;
*)
    echo "Usage: $0 {create|list|cleanup|rollback} [target_path_or_mountpoint]"
    exit 1
    ;;
esac
