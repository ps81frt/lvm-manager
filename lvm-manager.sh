#!/usr/bin/env bash
# =============================================================================
#  lvm-manager.sh — Gestionnaire LVM interactif
# =============================================================================
#  Description : Script tout-en-un pour gérer LVM sur Debian/Ubuntu/RHEL/Rocky
#                Diagnostic, création, extension, réduction, déplacement à chaud,
#                migration OS, snapshots — accessible aux débutants.
#
#  Compatibilité : Debian 10+, Ubuntu 20.04+, RHEL 8+, Rocky/Alma 8+
#  Dépendances   : lvm2, util-linux, e2fsprogs (ext4), xfsprogs (xfs)
#  Exécution     : sudo bash lvm-manager.sh
#
#  Auteur        : ps81rt
#  Licence       : MIT
#  Version       : 1.0.0
# =============================================================================

set -euo pipefail

# ─── Couleurs & mise en forme ──────────────────────────────────────────────
RED='\033[0;31m'
YEL='\033[0;33m'
GRN='\033[0;32m'
BLU='\033[0;34m'
CYN='\033[0;36m'
#WHT='\033[1;37m'
DIM='\033[2m'
BLD='\033[1m'
RST='\033[0m'

# ─── Fonctions d'affichage ─────────────────────────────────────────────────
info() { echo -e "${BLU}[INFO]${RST}  $*"; }
ok() { echo -e "${GRN}[  OK]${RST}  $*"; }
warn() { echo -e "${YEL}[WARN]${RST}  $*"; }
error() { echo -e "${RED}[ERREUR]${RST} $*" >&2; }
die() {
    error "$*"
    exit 1
}
sep() { echo -e "${DIM}────────────────────────────────────────────────────${RST}"; }
title() { echo -e "\n${BLD}${CYN}══ $* ══${RST}\n"; }
confirm() {
    local msg="${1:-Continuer ?}"
    echo -en "${YEL}[?]${RST} ${msg} ${DIM}(o/N)${RST} "
    read -r ans
    [[ "${ans,,}" == "o" || "${ans,,}" == "oui" || "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

execute_or_show() {
    local cmd="$1"
    echo
    echo -e "  ${BLD}Commande :${RST}"
    echo -e "    ${YEL}$cmd${RST}"
    echo
    echo -e "  ${BLD}Options :${RST}"
    echo -e "    ${BLD}1)${RST} Exécuter automatiquement"
    echo -e "    ${BLD}2)${RST} Afficher et copier manuellement"
    echo -e "    ${BLD}0)${RST} Passer"
    echo
    read -rp "$(echo -e "${CYN}Choix${RST} [0-2] : ")" choice

    case "$choice" in
    1)
        eval "$cmd"
        ;;
    2)
        echo
        echo -e "  ${DIM}Copie-colle cette commande :${RST}"
        echo -e "    ${YEL}$cmd${RST}"
        echo
        read -rp "$(echo -e "${DIM}  Appuyez sur Entrée une fois exécutée...${RST}")" _
        ;;
    *)
        info "Commandée ignorée."
        ;;
    esac
}

# ─── Vérifications préalables ──────────────────────────────────────────────
check_root() {
    [[ $EUID -eq 0 ]] || die "Ce script doit être exécuté en root (sudo bash $0)"
}

check_deps() {
    local missing=()

    for cmd in lvm pvs vgs lvs pvdisplay vgdisplay lvdisplay \
        pvcreate vgcreate lvcreate lvextend lvreduce lvremove \
        pvmove vgextend vgreduce pvremove lsblk blkid df \
        findmnt partprobe parted numfmt mountpoint mkfs.vfat; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done

    command -v efibootmgr &>/dev/null || missing+=("efibootmgr")

    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Commandes manquantes : ${missing[*]}"
        info "Installation des dépendances requises..."
        if command -v apt-get &>/dev/null; then
            apt-get update -y
            apt-get install -y lvm2 e2fsprogs xfsprogs util-linux parted dosfstools efibootmgr
        elif command -v dnf &>/dev/null; then
            dnf install -y lvm2 e2fsprogs xfsprogs util-linux parted dosfstools efibootmgr
        elif command -v yum &>/dev/null; then
            yum install -y lvm2 e2fsprogs xfsprogs util-linux parted dosfstools efibootmgr
        else
            die "Gestionnaire de paquets non reconnu. Installez lvm2 manuellement."
        fi

        local still_missing=()
        for cmd in "${missing[@]}"; do
            command -v "$cmd" &>/dev/null || still_missing+=("$cmd")
        done
        [[ ${#still_missing[@]} -eq 0 ]] || die "Dépendances toujours manquantes après installation : ${still_missing[*]}"
    fi
}

# ─── Bannière ──────────────────────────────────────────────────────────────
banner() {
    #clear
    echo -e "${BLD}${CYN}"
    cat <<'EOF'
  ██╗     ██╗   ██╗███╗   ███╗    ███╗   ███╗ ██████╗ ██████╗
  ██║     ██║   ██║████╗ ████║    ████╗ ████║██╔════╝ ██╔══██╗
  ██║     ██║   ██║██╔████╔██║    ██╔████╔██║██║  ███╗██████╔╝
  ██║     ╚██╗ ██╔╝██║╚██╔╝██║    ██║╚██╔╝██║██║   ██║██╔══██╗
  ███████╗ ╚████╔╝ ██║ ╚═╝ ██║    ██║ ╚═╝ ██║╚██████╔╝██║  ██║
  ╚══════╝  ╚═══╝  ╚═╝     ╚═╝    ╚═╝     ╚═╝ ╚═════╝ ╚═╝  ╚═╝
EOF
    echo -e "${RST}${DIM}  Gestionnaire LVM interactif v1.0.0 — Debian/Ubuntu/RHEL/Rocky${RST}"
    echo -e "${DIM}  Exécuté en tant que : $(whoami) | $(date '+%Y-%m-%d %H:%M:%S')${RST}\n"
}

# ═══════════════════════════════════════════════════════════════════════════
#  MODULE 1 — DIAGNOSTIC COMPLET
# ═══════════════════════════════════════════════════════════════════════════
diag_full() {
    title "DIAGNOSTIC LVM COMPLET"

    echo -e "${BLD}▶ Disques et partitions (lsblk)${RST}"
    sep
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,UUID | head -60
    echo

    echo -e "${BLD}▶ Physical Volumes (PV)${RST}"
    sep
    pvs -o pv_name,pv_size,pv_free,pv_used,pv_uuid,vg_name 2>/dev/null || warn "Aucun PV trouvé"
    echo

    echo -e "${BLD}▶ Volume Groups (VG)${RST}"
    sep
    vgs -o vg_name,vg_size,vg_free,vg_extent_size,pv_count,lv_count 2>/dev/null || warn "Aucun VG trouvé"
    echo

    echo -e "${BLD}▶ Logical Volumes (LV)${RST}"
    sep
    lvs -o lv_path,lv_size,lv_attr,seg_type,origin,data_percent,metadata_percent,copy_percent 2>/dev/null || warn "Aucun LV trouvé"
    echo

    echo -e "${BLD}▶ Systèmes de fichiers montés${RST}"
    sep
    df -hT | grep -E "^/dev/mapper|^/dev/[sv]d|Filesystem" || true
    echo

    echo -e "${BLD}▶ Résumé rapide${RST}"
    sep
    local pv_count vg_count lv_count
    pv_count=$(pvs --noheadings 2>/dev/null | grep -c .)
    vg_count=$(vgs --noheadings 2>/dev/null | wc -l)
    lv_count=$(lvs --noheadings 2>/dev/null | wc -l)
    echo -e "  PV : ${BLD}${pv_count}${RST}   VG : ${BLD}${vg_count}${RST}   LV : ${BLD}${lv_count}${RST}"
    echo

    echo -e "${BLD}▶ ZRAM (swap compressé)${RST}"
    sep
    if lsmod | grep -q zram; then
        echo -e "  ${GRN}Zram actif${RST}"
        echo -e "  Algorithmes dispo : $(cat /sys/block/zram0/comp_algorithm 2>/dev/null || echo 'N/A')"
        for dev in /sys/block/zram*/disksize; do
            if [[ -f "$dev" ]]; then
                size=$(cat "$dev" 2>/dev/null)
                name=$(echo "$dev" | cut -d/ -f4)
                echo "  $name : $(numfmt --to=iec "$size" 2>/dev/null || echo "$size")"
            fi
        done
        echo -e "  Swaps actifs :"
        swapon --show | grep -E "zram|NAME" | sed 's/^/    /'
    else
        echo -e "  ${DIM}Aucun zram actif${RST}"
    fi
    echo

    ok "Diagnostic terminé."
    pause
}

# ═══════════════════════════════════════════════════════════════════════════
#  MODULE 2 — CRÉER UN NOUVEAU LV
# ═══════════════════════════════════════════════════════════════════════════
create_lv() {
    title "CRÉER UN LOGICAL VOLUME"

    echo -e "${BLD}▶ Volume Groups disponibles :${RST}"
    vgs --noheadings -o vg_name,vg_size,vg_free 2>/dev/null || die "Aucun VG trouvé. Créez d'abord un PV et un VG."
    echo

    read -rp "$(echo -e "${CYN}Nom du VG cible${RST} : ")" VG_NAME
    vgs "$VG_NAME" &>/dev/null || die "VG '$VG_NAME' introuvable."

    read -rp "$(echo -e "${CYN}Nom du nouveau LV${RST} (ex: data, backup) : ")" LV_NAME
    [[ -z "$LV_NAME" ]] && die "Nom de LV vide."

    local vg_free
    vg_free=$(vgs --noheadings --units g -o vg_free "$VG_NAME" | tr -d ' g')
    info "Espace libre dans $VG_NAME : ${vg_free}G"

    read -rp "$(echo -e "${CYN}Taille${RST} (ex: 10G, 500M, 100%FREE) : ")" LV_SIZE

    echo -e "\n${BLD}▶ Choisir le système de fichiers :${RST}"
    echo "  1) ext4  (recommandé, supporte shrink)"
    echo "  2) xfs   (performant, pas de shrink)"
    echo "  3) Aucun (raw, pas de formatage)"
    read -rp "$(echo -e "${CYN}Choix${RST} [1-3] : ")" fs_choice

    sep
    info "Création du LV '$LV_NAME' (${LV_SIZE}) dans VG '$VG_NAME'..."
    confirm "Confirmer ?" || {
        warn "Annulé."
        return
    }

    if [[ "$LV_SIZE" == *"%FREE"* ]]; then
        lvcreate -l "$LV_SIZE" -n "$LV_NAME" "$VG_NAME"
    else
        lvcreate -L "$LV_SIZE" -n "$LV_NAME" "$VG_NAME"
    fi

    local lv_path="/dev/$VG_NAME/$LV_NAME"

    case "$fs_choice" in
    1)
        info "Formatage en ext4..."
        mkfs.ext4 -L "$LV_NAME" "$lv_path"
        ;;
    2)
        info "Formatage en xfs..."
        mkfs.xfs -L "$LV_NAME" "$lv_path"
        ;;
    3)
        warn "Aucun formatage — volume raw créé."
        ;;
    esac

    ok "LV créé : $lv_path"

    if [[ "$fs_choice" != "3" ]]; then
        echo
        read -rp "$(echo -e "${CYN}Point de montage${RST} (laisser vide pour ne pas monter) : ")" MOUNT_PT
        if [[ -n "$MOUNT_PT" ]]; then
            mkdir -p "$MOUNT_PT"
            mount "$lv_path" "$MOUNT_PT"
            ok "Monté sur $MOUNT_PT"

            if confirm "Ajouter à /etc/fstab (montage permanent) ?"; then
                local uuid
                uuid=$(blkid -s UUID -o value "$lv_path")
                echo "UUID=$uuid  $MOUNT_PT  $(blkid -s TYPE -o value "$lv_path")  defaults  0  2" >>/etc/fstab
                ok "Entrée ajoutée dans /etc/fstab (UUID: $uuid)"
            fi
        fi
    fi
    pause
}

# ═══════════════════════════════════════════════════════════════════════════
#  MODULE 3 — ÉTENDRE UN LV (à chaud)
# ═══════════════════════════════════════════════════════════════════════════
extend_lv() {
    title "ÉTENDRE UN LOGICAL VOLUME (à chaud)"

    echo -e "${BLD}▶ Logical Volumes disponibles :${RST}"
    lvs --noheadings -o lv_path,lv_size,vg_free 2>/dev/null
    echo

    read -rp "$(echo -e "${CYN}Chemin du LV à étendre${RST} (ex: /dev/vg0/root) : ")" LV_PATH
    lvdisplay "$LV_PATH" &>/dev/null || die "LV '$LV_PATH' introuvable."

    local fs_type
    fs_type=$(blkid -o value -s TYPE "$LV_PATH" 2>/dev/null || echo "inconnu")
    info "Filesystem détecté : ${BLD}${fs_type}${RST}"

    local vg_name
    vg_name=$(lvs --noheadings -o vg_name "$LV_PATH" | tr -d ' ')
    local vg_free
    vg_free=$(vgs --noheadings --units g -o vg_free "$vg_name" | tr -d ' g')
    info "Espace libre dans VG ($vg_name) : ${BLD}${vg_free}G${RST}"

    echo -e "\n  Format : ${YEL}+10G${RST} (ajouter) ou ${YEL}50G${RST} (taille finale) ou ${YEL}+100%FREE${RST}"
    read -rp "$(echo -e "${CYN}Nouvelle taille / ajout${RST} : ")" NEW_SIZE

    sep
    confirm "Étendre $LV_PATH de $NEW_SIZE ?" || {
        warn "Annulé."
        return
    }

    if [[ "$NEW_SIZE" == +* ]]; then
        lvextend -L "$NEW_SIZE" "$LV_PATH" ||
            lvextend -l "$NEW_SIZE" "$LV_PATH" || die "Échec lvextend"
    else
        lvextend -L "$NEW_SIZE" "$LV_PATH" || die "Échec lvextend"
    fi

    info "Extension du système de fichiers..."
    case "$fs_type" in
    ext2 | ext3 | ext4)
        resize2fs "$LV_PATH"
        ok "resize2fs terminé."
        ;;
    xfs)
        local mount_pt
        mount_pt=$(findmnt -n -o TARGET --source "$LV_PATH" 2>/dev/null || true)
        if [[ -z "$mount_pt" ]]; then
            warn "XFS doit être monté pour xfs_growfs. Montez le LV puis relancez."
        else
            xfs_growfs "$mount_pt"
            ok "xfs_growfs terminé."
        fi
        ;;
    *)
        warn "FS '$fs_type' non géré automatiquement. Redimensionnez manuellement."
        ;;
    esac

    echo
    lvs "$LV_PATH"
    ok "Extension terminée."
    pause
}

# ═══════════════════════════════════════════════════════════════════════════
#  MODULE 4 — RÉDUIRE UN LV (ext4 uniquement, démontage requis)
# ═══════════════════════════════════════════════════════════════════════════
shrink_lv() {
    title "RÉDUIRE UN LOGICAL VOLUME"

    warn "⚠  Opération DESTRUCTIVE si mal utilisée."
    warn "   Uniquement ext4. XFS ne supporte PAS le shrink."
    warn "   Le LV doit être DÉMONTÉ (sauf /boot avec LiveUSB)."
    echo

    echo -e "${BLD}▶ Logical Volumes disponibles :${RST}"
    lvs --noheadings -o lv_path,lv_size 2>/dev/null
    echo

    read -rp "$(echo -e "${CYN}Chemin du LV à réduire${RST} : ")" LV_PATH
    lvdisplay "$LV_PATH" &>/dev/null || die "LV introuvable."

    local fs_type
    fs_type=$(blkid -o value -s TYPE "$LV_PATH" 2>/dev/null || echo "inconnu")
    [[ "$fs_type" == xfs ]] && die "XFS ne supporte pas le shrink. Opération impossible."
    [[ "$fs_type" != ext* ]] && warn "FS '$fs_type' non ext — procédez avec précaution."

    read -rp "$(echo -e "${CYN}Nouvelle taille cible${RST} (ex: 20G) : ")" TARGET_SIZE

    sep
    warn "ATTENTION : toutes les données au-delà de $TARGET_SIZE seront PERDUES."
    confirm "Vous avez un snapshot ou une sauvegarde ?" || {
        warn "Opération annulée — faites d'abord un snapshot !"
        return
    }
    confirm "Confirmer la réduction à $TARGET_SIZE ?" || {
        warn "Annulé."
        return
    }

    # Démontage
    local mount_pt
    mount_pt=$(findmnt -n -o TARGET --source "$LV_PATH" 2>/dev/null || true)
    if [[ -n "$mount_pt" ]]; then
        warn "LV monté sur $mount_pt — démontage..."
        umount "$LV_PATH" || die "Impossible de démonter $LV_PATH (processus actif ?)"
    fi

    info "Vérification et réduction du FS..."
    e2fsck -f "$LV_PATH"
    local e2fsck_rc=$?
    if [[ $e2fsck_rc -ge 4 ]]; then
        die "e2fsck a détecté des erreurs non corrigées (code $e2fsck_rc) — abandon."
    fi
    [[ $e2fsck_rc -gt 0 ]] && warn "e2fsck a corrigé des erreurs mineures (code $e2fsck_rc)."
    info "Réduction du LV..."
    lvreduce --resizefs -L "$TARGET_SIZE" "$LV_PATH"

    info "Vérification finale..."
    e2fsck -f "$LV_PATH"
    e2fsck_rc=$?
    [[ $e2fsck_rc -ge 4 ]] && warn "e2fsck post-réduction : code $e2fsck_rc — vérifiez le volume."

    if [[ -n "$mount_pt" ]]; then
        mount "$LV_PATH" "$mount_pt"
        ok "LV remonté sur $mount_pt"
    fi

    lvs "$LV_PATH"
    ok "Réduction terminée."
    pause
}

# ═══════════════════════════════════════════════════════════════════════════
#  MODULE 5 — PVMOVE : DÉPLACER DES DONNÉES À CHAUD
# ═══════════════════════════════════════════════════════════════════════════
pvmove_data() {
    title "PVMOVE — DÉPLACER DES DONNÉES À CHAUD"

    info "pvmove déplace les extents LVM d'un PV vers un autre SANS démonter."
    info "Fonctionne même sur / (root), /home, /var en production."
    echo

    echo -e "${BLD}▶ Physical Volumes disponibles :${RST}"
    pvs -o pv_name,pv_size,pv_free,pv_used,vg_name 2>/dev/null
    echo

    read -rp "$(echo -e "${CYN}PV SOURCE à vider${RST} (ex: /dev/sdb) : ")" SRC_PV
    pvdisplay "$SRC_PV" &>/dev/null || die "PV '$SRC_PV' introuvable."

    local vg_name
    vg_name=$(pvs --noheadings -o vg_name "$SRC_PV" | tr -d ' ')
    [[ -z "$vg_name" ]] && die "Ce PV n'appartient à aucun VG."
    info "VG détecté : $vg_name"

    echo
    echo -e "  ${DIM}Laisser vide = répartition automatique sur tous les autres PV du VG${RST}"
    read -rp "$(echo -e "${CYN}PV DESTINATION${RST} (optionnel, ex: /dev/sdc) : ")" DST_PV

    sep
    if [[ -n "$DST_PV" ]]; then
        info "Déplacement : $SRC_PV → $DST_PV"
    else
        info "Déplacement : $SRC_PV → (automatique dans $vg_name)"
    fi

    # Estimation taille à déplacer
    local used_pe
    used_pe=$(pvs --noheadings -o pv_used "$SRC_PV" | tr -d ' ')
    warn "Données à déplacer : $used_pe — opération potentiellement longue."
    confirm "Démarrer pvmove ?" || {
        warn "Annulé."
        return
    }

    # Lancement en arrière-plan avec suivi
    if [[ -n "$DST_PV" ]]; then
        pvmove --verbose "$SRC_PV" "$DST_PV" &
    else
        pvmove --verbose "$SRC_PV" &
    fi
    local PVMOVE_PID=$!

    echo
    info "pvmove en cours (PID: $PVMOVE_PID) — progression :"
    sep
    while kill -0 "$PVMOVE_PID" 2>/dev/null; do
        local pct
        pct=$(lvs --noheadings -o copy_percent 2>/dev/null | grep -v '^$' | tail -1 | tr -d ' ')
        printf "\r  ${GRN}▶${RST} Progression : ${BLD}%s%%${RST}     " "${pct:-calcul...}"
        sleep 2
    done
    echo

    wait "$PVMOVE_PID"
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        die "pvmove a échoué (code $rc) — opération interrompue."
    fi
    ok "pvmove terminé !"

    echo
    info "Le PV $SRC_PV est maintenant vide."
    if confirm "Retirer $SRC_PV du VG '$vg_name' et le supprimer ?"; then
        vgreduce "$vg_name" "$SRC_PV"
        pvremove "$SRC_PV"
        ok "$SRC_PV retiré du VG et nettoyé."
    else
        info "Pour le faire plus tard :"
        echo -e "  ${YEL}vgreduce $vg_name $SRC_PV${RST}"
        echo -e "  ${YEL}pvremove $SRC_PV${RST}"
    fi
    pause
}

# ═══════════════════════════════════════════════════════════════════════════
#  MODULE 6 — SNAPSHOT LVM
# ═══════════════════════════════════════════════════════════════════════════
snapshot_lv() {
    title "SNAPSHOT LVM"

    echo "  ${BLD}1)${RST} Créer un snapshot"
    echo "  ${BLD}2)${RST} Lister les snapshots existants"
    echo "  ${BLD}3)${RST} Restaurer (merger) un snapshot"
    echo "  ${BLD}4)${RST} Supprimer un snapshot"
    echo
    read -rp "$(echo -e "${CYN}Choix${RST} [1-4] : ")" snap_action

    case "$snap_action" in
    1)
        echo -e "\n${BLD}▶ LV disponibles :${RST}"
        lvs --noheadings -o lv_path,lv_size,vg_name | grep -v snap
        echo
        read -rp "$(echo -e "${CYN}LV source du snapshot${RST} (ex: /dev/vg0/root) : ")" LV_SRC
        lvdisplay "$LV_SRC" &>/dev/null || die "LV introuvable."

        local snap_name
        snap_name="snap_$(basename "$LV_SRC")_$(date +%Y%m%d_%H%M)"
        info "Nom du snapshot : $snap_name"

        local lv_size suggested
        lv_size=$(lvs --noheadings --units g -o lv_size "$LV_SRC" | tr -d ' g' | cut -d. -f1)
        suggested=$((lv_size / 5))
        [[ $suggested -lt 1 ]] && suggested=1
        info "Taille suggérée (20% du LV = ${suggested}G)"

        read -rp "$(echo -e "${CYN}Taille du snapshot${RST} (ex: ${suggested}G) : ")" SNAP_SIZE
        [[ -z "$SNAP_SIZE" ]] && SNAP_SIZE="${suggested}G"

        local vg_name
        vg_name=$(lvs --noheadings -o vg_name "$LV_SRC" | tr -d ' ')
        lvcreate -L "$SNAP_SIZE" -s -n "$snap_name" "$LV_SRC"
        ok "Snapshot créé : /dev/$vg_name/$snap_name"
        info "Pour restaurer ultérieurement :"
        echo -e "  ${YEL}lvconvert --merge /dev/$vg_name/$snap_name${RST}"
        ;;
    2)
        echo
        echo -e "${BLD}▶ Snapshots LVM :${RST}"
        lvs --noheadings -o lv_path,lv_size,data_percent,origin -S "lv_attr =~ ^s" 2>/dev/null ||
            warn "Aucun snapshot trouvé."
        ;;
    3)
        echo -e "\n${BLD}▶ Snapshots disponibles :${RST}"
        lvs --noheadings -o lv_path,origin -S "lv_attr =~ ^s" 2>/dev/null
        echo
        read -rp "$(echo -e "${CYN}Chemin du snapshot à restaurer${RST} : ")" SNAP_PATH
        warn "La restauration écrasera les données actuelles du LV source."
        confirm "Confirmer la restauration ?" || {
            warn "Annulé."
            return
        }
        lvconvert --merge "$SNAP_PATH"
        ok "Merge demandé. Si le LV est / (root), redémarrez pour finaliser."
        ;;
    4)
        echo -e "\n${BLD}▶ Snapshots disponibles :${RST}"
        lvs --noheadings -o lv_path -S "lv_attr =~ ^s" 2>/dev/null
        echo
        read -rp "$(echo -e "${CYN}Chemin du snapshot à supprimer${RST} : ")" SNAP_DEL
        confirm "Supprimer définitivement $SNAP_DEL ?" || {
            warn "Annulé."
            return
        }
        lvremove -f "$SNAP_DEL"
        ok "Snapshot supprimé."
        ;;
    *)
        warn "Choix invalide."
        ;;
    esac
    pause
}

# ═══════════════════════════════════════════════════════════════════════════
#  MODULE 7 — AJOUTER UN DISQUE / ÉTENDRE LE VG
# ═══════════════════════════════════════════════════════════════════════════
add_disk_to_vg() {
    title "AJOUTER UN DISQUE / ÉTENDRE LE VG"

    echo -e "${BLD}▶ Disques disponibles (non LVM) :${RST}"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT | grep -E "disk|part" | head -30
    echo

    echo -e "${BLD}▶ Volume Groups existants :${RST}"
    vgs --noheadings -o vg_name,vg_size,vg_free 2>/dev/null || warn "Aucun VG trouvé."
    echo

    read -rp "$(echo -e "${CYN}Disque ou partition à ajouter${RST} (ex: /dev/sdc ou /dev/sdc1) : ")" NEW_DISK

    [[ -b "$NEW_DISK" ]] || die "$NEW_DISK n'est pas un périphérique bloc valide."

    # Vérifier si déjà utilisé
    local existing_use
    existing_use=$(blkid -o value -s TYPE "$NEW_DISK" 2>/dev/null || true)
    if [[ -n "$existing_use" ]]; then
        warn "$NEW_DISK contient déjà un filesystem : $existing_use"
        confirm "Continuer quand même (DONNÉES EFFACÉES) ?" || {
            warn "Annulé."
            return
        }
    fi

    read -rp "$(echo -e "${CYN}VG cible${RST} (laisser vide pour créer un nouveau VG) : ")" VG_TARGET

    sep
    info "Initialisation de $NEW_DISK en PV..."
    confirm "Confirmer pvcreate sur $NEW_DISK ?" || {
        warn "Annulé."
        return
    }
    pvcreate "$NEW_DISK"
    ok "PV créé : $NEW_DISK"

    if [[ -z "$VG_TARGET" ]]; then
        read -rp "$(echo -e "${CYN}Nom du nouveau VG${RST} : ")" NEW_VG
        [[ -z "$NEW_VG" ]] && die "Nom de VG vide."
        vgcreate "$NEW_VG" "$NEW_DISK"
        ok "VG '$NEW_VG' créé avec $NEW_DISK"
    else
        vgs "$VG_TARGET" &>/dev/null || die "VG '$VG_TARGET' introuvable."
        vgextend "$VG_TARGET" "$NEW_DISK"
        ok "$NEW_DISK ajouté au VG '$VG_TARGET'"
        vgs "$VG_TARGET"
    fi
    pause
}

# ═══════════════════════════════════════════════════════════════════════════
#  MODULE 8 — MIGRATION OS VERS NOUVEAU DISQUE
# ═══════════════════════════════════════════════════════════════════════════
migrate_os() {
    title "MIGRATION OS VERS NOUVEAU DISQUE (à chaud)"

    info "Ce module déplace l'intégralité d'un VG vers un nouveau disque."
    info "Aucun démontage requis — fonctionne en production."
    warn "Prévoyez ~1h pour un disque de 100Go selon les I/O."
    echo

    echo -e "${BLD}▶ Situation actuelle :${RST}"
    pvs -o pv_name,pv_size,pv_used,pv_free,vg_name
    echo

    local vg_names vg_choice vg_index
    mapfile -t vg_names < <(vgs --noheadings -o vg_name 2>/dev/null | awk '{$1=$1; print}')
    [[ ${#vg_names[@]} -gt 0 ]] || die "Aucun VG trouvé."

    if [[ ${#vg_names[@]} -eq 1 ]]; then
        VG_NAME="${vg_names[0]}"
        info "Un seul VG détecté : $VG_NAME (sélection automatique)"
    else
        echo -e "${BLD}▶ Choisir le VG à migrer :${RST}"
        for vg_index in "${!vg_names[@]}"; do
            local vg_item vg_size vg_free vg_pv_count
            vg_item="${vg_names[$vg_index]}"
            vg_size=$(vgs --noheadings -o vg_size "$vg_item" 2>/dev/null | awk '{$1=$1; print}')
            vg_free=$(vgs --noheadings -o vg_free "$vg_item" 2>/dev/null | awk '{$1=$1; print}')
            vg_pv_count=$(pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk -v vg="$vg_item" '$2==vg{c++} END{print c+0}')
            echo -e "  ${CYN}$((vg_index + 1)))${RST} $vg_item"
            echo -e "     ${DIM}PV: ${vg_pv_count} | taille: $vg_size | libre: $vg_free${RST}"
        done

        while true; do
            read -rp "$(echo -e "${CYN}Choix VG${RST} [1-${#vg_names[@]}] : ")" vg_choice
            [[ "$vg_choice" =~ ^[0-9]+$ ]] || {
                warn "Entrez un numéro valide."
                continue
            }
            if ((vg_choice >= 1 && vg_choice <= ${#vg_names[@]})); then
                VG_NAME="${vg_names[$((vg_choice - 1))]}"
                break
            fi
            warn "Choix hors plage."
        done
    fi
    info "VG sélectionné : $VG_NAME"

    local missing_used_bytes
    missing_used_bytes=$(pvs --noheadings --units b --nosuffix -o pv_name,pv_used,vg_name 2>/dev/null | awk -v vg="$VG_NAME" '$3==vg && $1=="[unknown]" {sum+=$2} END{printf "%.0f", sum+0}')
    [[ -n "$missing_used_bytes" ]] || missing_used_bytes=0

    if ((missing_used_bytes > 0)); then
        die "Le VG '$VG_NAME' contient des PV manquants avec des données. Corrigez d'abord l'état du VG avant migration."
    fi

    if pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk -v vg="$VG_NAME" '$2==vg && $1=="[unknown]" {found=1} END{exit(found?0:1)}'; then
        warn "Le VG '$VG_NAME' contient des PV manquants vides ([unknown]). Nettoyage en cours..."
        vgreduce --removemissing "$VG_NAME"
        ok "PV manquants vides retirés de $VG_NAME"
    fi

    local vg_pv_names pv_choice pv_index SOURCE_PV MIGRATION_SCOPE required_bytes_for_migration
    SOURCE_PV=""
    MIGRATION_SCOPE="full-vg"
    required_bytes_for_migration=0

    mapfile -t vg_pv_names < <(pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk -v vg="$VG_NAME" '$2==vg && $1 ~ /^\/dev\// {print $1}')
    [[ ${#vg_pv_names[@]} -gt 0 ]] || die "Aucun PV trouvé dans $VG_NAME."

    echo
    echo -e "${BLD}▶ Source à migrer :${RST}"
    for pv_index in "${!vg_pv_names[@]}"; do
        local pv_item pv_used pv_free
        pv_item="${vg_pv_names[$pv_index]}"
        pv_used=$(pvs --noheadings -o pv_used "$pv_item" 2>/dev/null | awk '{$1=$1; print}')
        pv_free=$(pvs --noheadings -o pv_free "$pv_item" 2>/dev/null | awk '{$1=$1; print}')
        echo -e "  ${CYN}$((pv_index + 1)))${RST} $pv_item  ${DIM}(utilisé: $pv_used | libre: $pv_free)${RST}"
    done
    if [[ ${#vg_pv_names[@]} -gt 1 ]]; then
        echo -e "  ${CYN}$((${#vg_pv_names[@]} + 1)))${RST} Tous les PV du VG ($VG_NAME)"
    fi

    while true; do
        if [[ ${#vg_pv_names[@]} -gt 1 ]]; then
            read -rp "$(echo -e "${CYN}Choix source${RST} [1-$((${#vg_pv_names[@]} + 1))] : ")" pv_choice
        else
            read -rp "$(echo -e "${CYN}Choix source${RST} [1] : ")" pv_choice
        fi

        [[ "$pv_choice" =~ ^[0-9]+$ ]] || {
            warn "Entrez un numéro valide."
            continue
        }

        if ((pv_choice >= 1 && pv_choice <= ${#vg_pv_names[@]})); then
            SOURCE_PV="${vg_pv_names[$((pv_choice - 1))]}"
            MIGRATION_SCOPE="single-pv"
            break
        fi

        if [[ ${#vg_pv_names[@]} -gt 1 ]] && ((pv_choice == ${#vg_pv_names[@]} + 1)); then
            MIGRATION_SCOPE="full-vg"
            break
        fi

        warn "Choix hors plage."
    done

    if [[ "$MIGRATION_SCOPE" == "single-pv" ]]; then
        info "Source sélectionnée : $SOURCE_PV"
        required_bytes_for_migration=$(pvs --noheadings --units b --nosuffix -o pv_used "$SOURCE_PV" 2>/dev/null | awk '{sum+=$1} END{printf "%.0f", sum+0}')
    else
        info "Source sélectionnée : tous les PV de $VG_NAME"
        required_bytes_for_migration=$(pvs --noheadings --units b --nosuffix -o pv_used,vg_name 2>/dev/null | awk -v vg="$VG_NAME" '$2==vg {sum+=$1} END{printf "%.0f", sum+0}')
    fi

    [[ -n "$required_bytes_for_migration" ]] || die "Impossible d'estimer les données à migrer."
    if ((required_bytes_for_migration < 0)); then
        die "Valeur invalide pour les données à migrer."
    fi
    if ((required_bytes_for_migration == 0)); then
        warn "Aucune donnée utilisée à déplacer pour la source choisie."
    fi

    echo -e "\n${BLD}▶ Disques et partitions disponibles :${RST}"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT | grep -E "disk|part"
    echo
    echo -e "  ${DIM}Vous pouvez cibler un disque entier${RST} ${YEL}(ex: /dev/sdb)${RST}"
    echo -e "  ${DIM}ou une partition spécifique        ${RST} ${YEL}(ex: /dev/sdX3 ou /dev/nvme0n1p3)${RST}"
    echo -e "  ${YEL}⚠  Cibler une partition préserve EFI/boot sur les autres partitions${RST}"
    echo

    local disk_candidates
    disk_candidates=$(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print "/dev/"$1}' | paste -sd ', ' -)

    while true; do
        read -rp "$(echo -e "${CYN}Destination (disque ou partition)${RST} : ")" NEW_DISK

        if [[ -z "$NEW_DISK" ]]; then
            warn "Saisie vide."
            continue
        fi

        if [[ "$NEW_DISK" =~ ^[qQ]$ ]]; then
            warn "Annulé."
            return
        fi

        if [[ "$NEW_DISK" == /deb/* ]]; then
            local suggested_dev
            suggested_dev="${NEW_DISK/\/deb\//\/dev\/}"
            warn "Chemin suspect détecté : $NEW_DISK"
            if [[ -b "$suggested_dev" ]] && confirm "Utiliser '$suggested_dev' à la place ?"; then
                NEW_DISK="$suggested_dev"
            fi
        elif [[ "$NEW_DISK" != /dev/* ]]; then
            local suggested_short
            suggested_short="/dev/$NEW_DISK"
            if [[ -b "$suggested_short" ]] && confirm "Utiliser '$suggested_short' à la place ?"; then
                NEW_DISK="$suggested_short"
            fi
        fi

        if [[ -b "$NEW_DISK" ]]; then
            break
        fi

        error "Périphérique '$NEW_DISK' invalide ou introuvable."
        info "Exemples valides : /dev/sdb, /dev/sdb1"
        [[ -n "$disk_candidates" ]] && info "Disques détectés : $disk_candidates"
    done

    local NEW_PV="$NEW_DISK"

    # Déterminer si c'est un disque entier ou une partition
    local dev_type
    dev_type=$(lsblk -dn -o TYPE "$NEW_DISK" 2>/dev/null || echo "unknown")

    local existing_use
    existing_use=$(blkid -o value -s TYPE "$NEW_DISK" 2>/dev/null || true)

    if [[ "$dev_type" == "disk" ]]; then
        local has_efi has_boot
        has_efi=$(lsblk -ln -o NAME,PARTTYPE "$NEW_DISK" 2>/dev/null | grep -i -c "c12a7328\|efi" || true)
        has_boot=$(lsblk -ln -o NAME,FSTYPE,MOUNTPOINT "$NEW_DISK" 2>/dev/null | grep -E -c "/boot|vfat" || true)

        echo
        echo -e "${BLD}▶ Mode de migration sur disque entier :${RST}"
        echo -e "  ${CYN}1)${RST} Utiliser ${YEL}$NEW_DISK${RST} en PV brut ${DIM}(destructif, efface la table de partitions)${RST}"
        echo -e "  ${CYN}2)${RST} Préserver multi-boot/EFI et créer une partition LVM dans l'espace libre"
        echo -e "  ${CYN}0)${RST} Annuler"
        echo

        local disk_mode
        read -rp "$(echo -e "${CYN}Choix${RST} [0-2] : ")" disk_mode
        case "$disk_mode" in
        0)
            warn "Annulé."
            return
            ;;
        1)
            ;;
        2)
            command -v parted &>/dev/null || die "parted requis pour créer une partition LVM en conservant le multi-boot."
            echo
            info "Vue du disque et des espaces libres :"
            lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$NEW_DISK"
            echo
            local current_pttype created_new_label
            current_pttype=$(lsblk -dn -o PTTYPE "$NEW_DISK" 2>/dev/null || true)
            created_new_label=0

            if ! parted -s "$NEW_DISK" print free; then
                echo
                warn "Aucune table de partitions détectée sur $NEW_DISK."
                confirm "Initialiser une table GPT sur $NEW_DISK ?" || {
                    warn "Annulé."
                    return
                }
                parted -s "$NEW_DISK" mklabel gpt || die "Impossible de créer la table GPT sur $NEW_DISK."
                partprobe "$NEW_DISK" || true
                created_new_label=1
                ok "Table GPT créée sur $NEW_DISK"
                parted -s "$NEW_DISK" print free || true
            fi
            echo

            local lvm_partnum lvm_start lvm_end default_start default_end
            local before_parts after_parts
            mapfile -t before_parts < <(lsblk -nr -o PATH,TYPE "$NEW_DISK" 2>/dev/null | awk '$2=="part"{print $1}')

            local reserve_efi_start
            reserve_efi_start=0
            if [[ "$created_new_label" -eq 1 ]] || [[ -z "$current_pttype" ]]; then
                if [[ -d /sys/firmware/efi ]] && [[ "$has_efi" -eq 0 ]]; then
                    reserve_efi_start=1
                    info "Mode UEFI détecté : réserve de 550MiB au début pour l'ESP (EFI)."
                fi
            fi

            local required_mib_for_vg
            required_mib_for_vg=$(((required_bytes_for_migration + 1048575) / 1048576))
            ((required_mib_for_vg > 0)) || required_mib_for_vg=1

            [[ -n "$required_mib_for_vg" && "$required_mib_for_vg" -gt 0 ]] || die "Impossible d'estimer l'espace requis pour migrer '$VG_NAME'."
            info "Espace minimum requis pour migrer '$VG_NAME' : ${required_mib_for_vg}MiB"

            local best_start_mib best_end_mib best_size_mib largest_free_mib
            best_start_mib=""
            best_end_mib=""
            best_size_mib=0
            largest_free_mib=0

            while IFS=':' read -r fs fe; do
                [[ -z "$fs" || -z "$fe" ]] && continue

                local s_ceil e_floor candidate_start size_mib
                s_ceil=$(awk -v v="$fs" 'BEGIN{print (v==int(v)?int(v):int(v)+1)}')
                e_floor=$(awk -v v="$fe" 'BEGIN{print int(v)}')
                candidate_start="$s_ceil"

                if [[ "$reserve_efi_start" -eq 1 ]] && ((candidate_start < 551)) && ((e_floor > 551)); then
                    candidate_start=551
                fi

                ((e_floor > candidate_start)) || continue
                size_mib=$((e_floor - candidate_start))

                if ((size_mib > largest_free_mib)); then
                    largest_free_mib=$size_mib
                fi

                ((size_mib >= required_mib_for_vg)) || continue

                if ((size_mib > best_size_mib)); then
                    best_size_mib=$size_mib
                    best_start_mib="$candidate_start"
                    best_end_mib="$e_floor"
                fi
            done < <(parted -m -s "$NEW_DISK" unit MiB print free 2>/dev/null | awk -F: '/free/ {gsub("MiB","",$2); gsub("MiB","",$3); print $2":"$3}')

            if [[ -z "$best_start_mib" || -z "$best_end_mib" ]]; then
                warn "Aucun espace libre suffisant sur $NEW_DISK pour migrer '$VG_NAME'."
                info "Plus grand espace libre trouvé : ${largest_free_mib}MiB"
                info "Espace requis : ${required_mib_for_vg}MiB"
                echo
                warn "Solutions :"
                echo "  - Utiliser une partition existante plus grande (ex: /dev/sdX1)"
                echo "  - Libérer/agrandir l'espace libre sur $NEW_DISK"
                echo "  - Utiliser le mode disque entier (destructif)"
                return
            fi

            default_start="${best_start_mib}MiB"
            default_end="${best_end_mib}MiB"
            info "Plage libre proposée automatiquement : $default_start -> $default_end"

            read -rp "$(echo -e "${CYN}Début partition${RST} (ex: 1MiB, 10GiB, 10GB, 70%) [${default_start}] : ")" lvm_start
            read -rp "$(echo -e "${CYN}Fin partition${RST} (ex: 100%, 60GiB, 60GB) [${default_end}] : ")" lvm_end
            [[ -z "$lvm_start" ]] && lvm_start="$default_start"
            [[ -z "$lvm_end" ]] && lvm_end="$default_end"
            info "Plage retenue : $lvm_start -> $lvm_end"

            confirm "Créer une nouvelle partition LVM dans l'espace libre ?" || {
                warn "Annulé."
                return
            }

            parted -s "$NEW_DISK" mkpart primary "$lvm_start" "$lvm_end"
            partprobe "$NEW_DISK" || true

            mapfile -t after_parts < <(lsblk -nr -o PATH,TYPE "$NEW_DISK" 2>/dev/null | awk '$2=="part"{print $1}')
            NEW_PV=""
            for p in "${after_parts[@]}"; do
                local seen=0
                for bp in "${before_parts[@]}"; do
                    if [[ "$bp" == "$p" ]]; then
                        seen=1
                        break
                    fi
                done
                if [[ "$seen" -eq 0 ]]; then
                    NEW_PV="$p"
                    break
                fi
            done

            if [[ -z "$NEW_PV" && ${#after_parts[@]} -gt 0 ]]; then
                NEW_PV="${after_parts[-1]}"
            fi

            [[ -b "$NEW_PV" ]] || die "Impossible de détecter la nouvelle partition LVM sur $NEW_DISK."

            lvm_partnum=$(lsblk -no PARTN "$NEW_PV" 2>/dev/null | tr -d ' ')
            [[ "$lvm_partnum" =~ ^[0-9]+$ ]] || die "Impossible de déterminer le numéro de partition pour $NEW_PV."
            parted -s "$NEW_DISK" set "$lvm_partnum" lvm on
            partprobe "$NEW_DISK" || true

            [[ -b "$NEW_PV" ]] || die "Partition LVM $NEW_PV introuvable après création."
            ok "Partition LVM créée : $NEW_PV"
            ;;
        *)
            die "Choix invalide."
            ;;
        esac

        if [[ "$disk_mode" == "1" ]] && [[ "$has_efi" -gt 0 || "$has_boot" -gt 0 ]]; then
            echo
            warn "⚠  ATTENTION : $NEW_DISK contient des partitions EFI ou /boot !"
            lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT "$NEW_DISK"
            echo
            warn "Écraser le disque entier DÉTRUIRA le bootloader."
            echo -e "  ${BLD}Conseil :${RST} ciblez uniquement la partition LVM (ex: ${YEL}/dev/sdX3${RST})"
            echo
            confirm "Continuer quand même sur le disque ENTIER (dangereux) ?" || {
                warn "Annulé — relancez et choisissez une partition spécifique."
                return
            }
        elif [[ "$disk_mode" == "1" ]]; then
            [[ -n "$existing_use" ]] && warn "$NEW_DISK contient : $existing_use — sera écrasé."
        fi

        sep
        if [[ "$disk_mode" == "1" ]]; then
            warn "RÉSUMÉ : Migration de $VG_NAME vers $NEW_DISK (disque entier)"
            warn "Le disque $NEW_DISK sera ENTIÈREMENT écrasé."
        else
            info "RÉSUMÉ : Migration de $VG_NAME vers la partition LVM $NEW_PV"
            info "EFI/multi-boot préservés sur $NEW_DISK."
        fi

    else
        # Cible = partition : vérifier qu'elle n'est pas montée
        local part_mount
        part_mount=$(findmnt -n -o TARGET --source "$NEW_DISK" 2>/dev/null || true)
        if [[ -n "$part_mount" ]]; then
            die "$NEW_DISK est actuellement monté sur $part_mount — démontez-la d'abord."
        fi

        local parent_disk
        parent_disk=$(lsblk -dn -o PKNAME "$NEW_DISK" 2>/dev/null | tr -d ' ')
        [[ -n "$parent_disk" ]] && parent_disk="/dev/$parent_disk" || parent_disk="(inconnu)"

        if [[ -n "$existing_use" ]]; then
            warn "$NEW_DISK contient : $existing_use — sera écrasé."
        else
            info "$NEW_DISK est vide / non formatée."
        fi
        info "Disque parent : $parent_disk — les autres partitions ne seront PAS touchées."

        sep
        warn "RÉSUMÉ : Migration de $VG_NAME vers la partition $NEW_DISK uniquement"
        info "EFI, /boot et les autres partitions de $parent_disk sont préservées."
    fi

    confirm "Démarrer la migration ?" || {
        warn "Annulé."
        return
    }

    local required_bytes target_bytes
    required_bytes="$required_bytes_for_migration"
    target_bytes=$(lsblk -bnd -o SIZE "$NEW_PV" 2>/dev/null || echo 0)

    if [[ -z "$required_bytes" || "$required_bytes" -lt 0 ]]; then
        die "Impossible d'estimer la taille des données à migrer pour le VG '$VG_NAME'."
    fi

    if [[ -z "$target_bytes" || "$target_bytes" -le 0 ]]; then
        die "Impossible de lire la taille de la cible '$NEW_PV'."
    fi

    if ((target_bytes < required_bytes)); then
        warn "Espace insuffisant sur $NEW_PV pour migrer $VG_NAME."
        info "Données à migrer : $(numfmt --to=iec "$required_bytes" 2>/dev/null || echo "$required_bytes")"
        info "Capacité cible :  $(numfmt --to=iec "$target_bytes" 2>/dev/null || echo "$target_bytes")"
        echo
        warn "Solutions :"
        echo "  - Choisir une partition cible plus grande (ex: /dev/sdX1)"
        echo "  - Libérer/agrandir l'espace libre sur le disque cible"
        echo "  - Utiliser le mode disque entier (destructif) si acceptable"
        return
    fi

    if [[ "$dev_type" == "disk" && "${disk_mode:-}" == "1" ]]; then
        local vg_pvs_on_target_disk
        mapfile -t vg_pvs_on_target_disk < <(pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk -v vg="$VG_NAME" -v d="$NEW_DISK" '$2==vg && index($1, d)==1 {print $1}')

        if [[ ${#vg_pvs_on_target_disk[@]} -gt 0 ]]; then
            info "PV(s) du VG '$VG_NAME' détecté(s) sur le disque cible : ${vg_pvs_on_target_disk[*]}"
            local child_pv
            for child_pv in "${vg_pvs_on_target_disk[@]}"; do
                local child_used_bytes
                child_used_bytes=$(pvs --noheadings --units b --nosuffix -o pv_used "$child_pv" 2>/dev/null | awk '{printf "%.0f", $1+0}')
                [[ -n "$child_used_bytes" ]] || child_used_bytes=0

                if ((child_used_bytes > 0)); then
                    die "Le disque cible $NEW_DISK contient déjà un PV utilisé du VG ($child_pv). Choisissez une autre destination ou migrez d'abord ce PV."
                fi

                info "Retrait du PV vide $child_pv du VG avant effacement disque..."
                vgreduce "$VG_NAME" "$child_pv"
                pvremove "$child_pv" || true
                ok "$child_pv retiré de $VG_NAME"
            done
        fi

        local mounted_children
        mounted_children=$(lsblk -nr -o PATH,MOUNTPOINT "$NEW_DISK" 2>/dev/null | awk '$2!="" {print $1" -> "$2}')
        if [[ -n "$mounted_children" ]]; then
            die "Le disque $NEW_DISK a des partitions montées:\n$mounted_children\nDémontez-les avant migration destructive."
        fi

        info "Préparation du disque entier $NEW_DISK (effacement signatures/partitions)..."
        wipefs -af "$NEW_DISK" || true
        if command -v sgdisk &>/dev/null; then
            sgdisk --zap-all "$NEW_DISK" || true
        fi
        partprobe "$NEW_DISK" || true
        udevadm settle 2>/dev/null || true
    fi

    # Étape 1 : pvcreate sur le nouveau disque
    info "[1/5] Initialisation du nouveau PV..."
    if pvs "$NEW_PV" &>/dev/null; then
        warn "$NEW_PV est déjà un PV LVM."
        confirm "Le réutiliser tel quel (sans pvcreate) ?" || pvcreate --yes -ff "$NEW_PV"
    else
        pvcreate --yes -ff "$NEW_PV"
    fi
    ok "$NEW_PV initialisé en PV."

    # Étape 2 : Ajouter au VG
    info "[2/5] Ajout au VG '$VG_NAME'..."
    vgextend "$VG_NAME" "$NEW_PV"
    ok "$NEW_PV ajouté à $VG_NAME."

    # Étape 3 : Récupérer les PV source selon la portée choisie
    local old_pvs
    if [[ "$MIGRATION_SCOPE" == "single-pv" ]]; then
        [[ "$SOURCE_PV" != "$NEW_PV" ]] || die "La destination doit être différente du PV source ($SOURCE_PV)."
        old_pvs=("$SOURCE_PV")
    else
        mapfile -t old_pvs < <(pvs --noheadings -o pv_name,vg_name | awk -v vg="$VG_NAME" -v nd="$NEW_PV" '$2==vg && $1!=nd && $1 ~ /^\/dev\// {print $1}')
    fi
    [[ ${#old_pvs[@]} -eq 0 ]] && die "Aucun PV source distinct de $NEW_PV trouvé dans $VG_NAME."

    info "[3/5] PV source(s) détectés : ${old_pvs[*]}"

    # Étape 4 : pvmove pour chaque ancien PV
    local i=1
    for OLD_PV in "${old_pvs[@]}"; do
        info "[4/5] pvmove $OLD_PV → $NEW_PV ($i/${#old_pvs[@]})..."
        pvmove --verbose "$OLD_PV" "$NEW_PV" &
        local PID=$!
        while kill -0 "$PID" 2>/dev/null; do
            local pct
            pct=$(lvs --noheadings -o copy_percent 2>/dev/null | grep -v '^$' | tail -1 | tr -d ' ')
            printf "\r  ${GRN}▶${RST} %s : %s%%     " "$OLD_PV" "${pct:-...}"
            sleep 2
        done
        echo
        wait "$PID"
        local rc=$?
        if [[ $rc -ne 0 ]]; then
            die "pvmove a échoué pour $OLD_PV (code $rc) — migration interrompue."
        fi
        ok "pvmove terminé pour $OLD_PV"
        ((i++))
    done

    # Étape 5 : Retirer les anciens PV
    info "[5/5] Retrait des anciens PV..."
    for OLD_PV in "${old_pvs[@]}"; do
        vgreduce "$VG_NAME" "$OLD_PV"
        pvremove "$OLD_PV"
        ok "$OLD_PV retiré."
    done

    echo
    ok "═══ MIGRATION TERMINÉE ═══"
    pvs
    vgs "$VG_NAME"

    warn "IMPORTANT — Dernières étapes manuelles requises :"
    echo

    _BOOT_DISK="$NEW_DISK"
    # shellcheck disable=SC2001
    case "$NEW_DISK" in
    /dev/nvme*p[0-9]*) _BOOT_DISK=$(echo "$NEW_DISK" | sed 's/p[0-9]*$//') ;;
    *[0-9]) _BOOT_DISK=$(echo "$NEW_DISK" | sed 's/[0-9]*$//') ;;
    esac

    _IS_EFI=0
    test -d /sys/firmware/efi && _IS_EFI=1

    _DISTRO_ID="unknown"
    _DISTRO_LIKE=""
    if test -f /etc/os-release; then
        # shellcheck disable=SC1091
        _DISTRO_ID=$(. /etc/os-release && echo "${ID:-unknown}")
        # shellcheck disable=SC1091
        _DISTRO_LIKE=$(. /etc/os-release && echo "${ID_LIKE:-}")
    fi

    _BOOTLOADER="unknown"
    if test -d /boot/efi/EFI/refind || test -d /efi/EFI/refind || command -v refind-install >/dev/null 2>&1; then
        _BOOTLOADER="refind"
    elif test -d /boot/efi/EFI/systemd || test -d /efi/EFI/systemd ||
        { command -v bootctl >/dev/null 2>&1 && bootctl is-installed >/dev/null 2>&1; }; then
        _BOOTLOADER="systemd-boot"
    elif command -v grub2-install >/dev/null 2>&1; then
        _BOOTLOADER="grub2"
    elif command -v grub-install >/dev/null 2>&1; then
        _BOOTLOADER="grub"
    elif command -v extlinux >/dev/null 2>&1 || test -d /boot/syslinux || test -d /boot/extlinux; then
        _BOOTLOADER="syslinux"
    fi

    # shellcheck disable=SC2016
    _INITRAMFS_CMD="dracut -f --regenerate-all"
    case "$_DISTRO_ID" in
    arch | manjaro | endeavouros | artix | parabola) _INITRAMFS_CMD="mkinitcpio -P" ;;
    alpine) _INITRAMFS_CMD="mkinitfs" ;;
    void) _INITRAMFS_CMD="xbps-reconfigure -f $(xbps-query -s linux | awk 'NR==1{print $2}' | cut -d- -f1,2)" ;;
    gentoo) _INITRAMFS_CMD="genkernel --install initramfs" ;;
    debian | ubuntu | linuxmint | pop | kali | raspbian) _INITRAMFS_CMD="update-initramfs -u -k all" ;;
    *)
        case "$_DISTRO_LIKE" in
        *arch*) _INITRAMFS_CMD="mkinitcpio -P" ;;
        *debian* | *ubuntu*) _INITRAMFS_CMD="update-initramfs -u -k all" ;;
        esac
        ;;
    esac

    _GRUB_MKCONFIG="grub-mkconfig -o /boot/grub/grub.cfg"
    case "$_DISTRO_ID" in
    debian | ubuntu | linuxmint | pop | kali | raspbian) _GRUB_MKCONFIG="update-grub" ;;
    fedora | rhel | centos | rocky | almalinux | ol | opensuse* | sles)
        _GRUB_MKCONFIG="grub2-mkconfig -o /boot/grub2/grub.cfg"
        ;;
    *)
        case "$_DISTRO_LIKE" in
        *debian* | *ubuntu*) _GRUB_MKCONFIG="update-grub" ;;
        *fedora* | *rhel* | *suse*) _GRUB_MKCONFIG="grub2-mkconfig -o /boot/grub2/grub.cfg" ;;
        esac
        ;;
    esac

    echo -e "  ${BLD}Distro :${RST}     $_DISTRO_ID"
    echo -e "  ${BLD}Bootloader :${RST} $_BOOTLOADER"
    echo -e "  ${BLD}Firmware :${RST}   $([ "$_IS_EFI" -eq 1 ] && echo 'UEFI' || echo 'BIOS/Legacy')"
    echo

    read -rp "$(echo -e "${CYN}▶ /boot est-il sur le VG migré '$VG_NAME' ?${RST} [o/N] ")" _ANS_BOOT
    _BOOT_ON_VG="n"
    [[ "$_ANS_BOOT" =~ ^[oOyY] ]] && _BOOT_ON_VG="y"

    _EFI_DIR="/boot/efi"
    if test -d /efi/EFI && ! test -d /boot/efi/EFI; then
        _EFI_DIR="/efi"
    fi

    _EFI_SHARED="n"
    if [ "$_IS_EFI" -eq 1 ] && [ "$_BOOT_ON_VG" = "y" ]; then
        read -rp "$(echo -e "${CYN}▶ La partition EFI est-elle partagée avec un autre disque non migré ?${RST} [o/N] ")" _ANS_EFI
        [[ "$_ANS_EFI" =~ ^[oOyY] ]] && _EFI_SHARED="y"
    fi

    echo

    if [ "$_BOOT_ON_VG" = "n" ]; then
        echo -e "  ${BLD}✓ /boot est sur un disque séparé — aucune action bootloader requise.${RST}"
        echo
    else
        if [ "$_BOOTLOADER" = "refind" ]; then
            echo -e "  ${BLD}rEFInd :${RST}"
            if [ "$_EFI_SHARED" = "y" ]; then
                echo -e "    Partition EFI partagée — rEFInd reste accessible, aucune réinstallation requise."
            else
                execute_or_show "refind-install"
            fi
            echo

        elif [ "$_BOOTLOADER" = "systemd-boot" ]; then
            echo -e "  ${BLD}systemd-boot :${RST}"
            if [ "$_EFI_SHARED" = "y" ]; then
                execute_or_show "bootctl status"
            else
                execute_or_show "bootctl install --esp-path=$_EFI_DIR"
                execute_or_show "bootctl update"
                execute_or_show "bootctl status"
            fi
            echo

        elif [ "$_BOOTLOADER" = "grub2" ]; then
            echo -e "  ${BLD}GRUB2 :${RST}"
            if [ "$_IS_EFI" -eq 1 ]; then
                execute_or_show "grub2-install --target=x86_64-efi --efi-directory=$_EFI_DIR --bootloader-id=grub"
            else
                execute_or_show "grub2-install $_BOOT_DISK"
            fi
            execute_or_show "$_GRUB_MKCONFIG"
            execute_or_show "$_INITRAMFS_CMD"
            echo

        elif [ "$_BOOTLOADER" = "grub" ]; then
            echo -e "  ${BLD}GRUB :${RST}"
            if [ "$_IS_EFI" -eq 1 ]; then
                execute_or_show "grub-install --target=x86_64-efi --efi-directory=$_EFI_DIR --bootloader-id=grub"
            else
                execute_or_show "grub-install $_BOOT_DISK"
            fi
            execute_or_show "$_GRUB_MKCONFIG"
            execute_or_show "$_INITRAMFS_CMD"
            echo

        elif [ "$_BOOTLOADER" = "syslinux" ]; then
            echo -e "  ${BLD}syslinux/extlinux :${RST}"
            execute_or_show "extlinux --install /boot/syslinux"
            execute_or_show "dd bs=440 count=1 conv=notrunc if=/usr/lib/syslinux/mbr/mbr.bin of=$_BOOT_DISK"
            echo

        else
            echo -e "  ${BLD}Bootloader non détecté — commandes génériques :${RST}"
            if [ "$_IS_EFI" -eq 1 ]; then
                execute_or_show "grub-install --target=x86_64-efi --efi-directory=$_EFI_DIR --bootloader-id=grub"
            else
                execute_or_show "grub-install $_BOOT_DISK"
            fi
            execute_or_show "$_GRUB_MKCONFIG"
            execute_or_show "$_INITRAMFS_CMD"
            echo
        fi
    fi

    echo -e "\n${BLD}▶ Mise à jour de /etc/fstab :${RST}"
    echo
    local fstab_lines
    fstab_lines=$(grep -E "$VG_NAME|$NEW_DISK" /etc/fstab 2>/dev/null || echo "Aucune ligne trouvée")

    if [[ "$fstab_lines" == "Aucune ligne trouvée" ]]; then
        info "Aucune entrée directe du VG/disque dans fstab — ignorées."
    else
        echo -e "  ${DIM}Lignes concernées :${RST}"
        echo "$fstab_lines" | sed 's/^/    /'
        echo
        warn "Vérifiez que ces entrées utilisent UUID ou /dev/mapper/VG-LV"
    fi

    echo
    echo -e "${BLD}▶ Tous les LV migrés et leurs UUID :${RST}"
    lvs --noheadings -o lv_path,lv_name "$VG_NAME" 2>/dev/null | while read -r lv_path lv_name; do
        local uuid
        uuid=$(blkid -s UUID -o value "$lv_path" 2>/dev/null || echo "N/A")
        echo "    $lv_path → UUID=$uuid"
    done
    echo

    echo -e "${BLD}▶ Actions :${RST}"
    echo -e "  ${CYN}1)${RST} Ajouter/modifier une entrée fstab"
    echo -e "  ${CYN}2)${RST} Voir les options recommandées"
    echo -e "  ${CYN}3)${RST} Éditer manuellement /etc/fstab"
    echo -e "  ${CYN}4)${RST} Vérifier la syntaxe"
    echo -e "  ${CYN}5)${RST} Continuer"
    echo
    read -rp "$(echo -e "${CYN}Choix${RST} [1-5] : ")" fstab_choice

    case "$fstab_choice" in
    1)
        echo -e "\n${BLD}Ajouter/modifier une entrée${RST}"
        echo

        read -rp "$(echo -e "${CYN}Chemin du device${RST} : ")" DEV_PATH
        [[ -z "$DEV_PATH" ]] && {
            warn "Chemin vide — annulé."
        } || {
            local device_to_use="$DEV_PATH"
            if [[ "$DEV_PATH" == UUID=* ]]; then
                local uuid_val=${DEV_PATH#UUID=}
                local blk_dev
                blk_dev=$(blkid -U "$uuid_val" 2>/dev/null || echo "")
                if [[ -n "$blk_dev" ]]; then
                    device_to_use="$blk_dev"
                fi
            fi

            local fs_type detected_uuid mount_pt
            fs_type=$(blkid -s TYPE -o value "$device_to_use" 2>/dev/null || echo "ext4")
            detected_uuid=$(blkid -s UUID -o value "$device_to_use" 2>/dev/null || echo "")

            info "Filesystem : $fs_type"
            [[ -n "$detected_uuid" ]] && info "UUID : UUID=$detected_uuid"
            echo

            read -rp "$(echo -e "${CYN}Point de montage${RST} : ")" mount_pt
            [[ -z "$mount_pt" ]] && mount_pt="/"

            local default_opts
            case "$fs_type" in
            ext4) default_opts="defaults,noatime" ;;
            btrfs) default_opts="defaults,compress=zstd:3" ;;
            xfs) default_opts="defaults,noatime" ;;
            vfat) default_opts="defaults,umask=0022" ;;
            ntfs-3g) default_opts="uid=1000,gid=1000,umask=0022" ;;
            swap) default_opts="defaults" ;;
            *) default_opts="defaults" ;;
            esac

            echo -e "  Options : ${YEL}$default_opts${RST}"
            read -rp "$(echo -e "${CYN}Options mount${RST} (vide=défaut) : ")" custom_opts
            [[ -z "$custom_opts" ]] && custom_opts="$default_opts"

            local dump_val fsck_val
            if [[ "$mount_pt" == "/" ]]; then
                fsck_val=1
                dump_val=0
            elif [[ "$mount_pt" == "/boot"* ]]; then
                fsck_val=2
                dump_val=0
            else
                fsck_val=2
                dump_val=0
            fi

            local fstab_entry
            fstab_entry="UUID=$detected_uuid    $mount_pt    $fs_type    $custom_opts    $dump_val    $fsck_val"

            if [[ -z "$detected_uuid" ]]; then
                fstab_entry="$DEV_PATH    $mount_pt    $fs_type    $custom_opts    $dump_val    $fsck_val"
            fi

            echo
            echo -e "${BLD}Proposé :${RST}"
            echo -e "  ${YEL}$fstab_entry${RST}"
            echo

            if confirm "Ajouter à /etc/fstab ?"; then
                if [[ -n "$detected_uuid" ]]; then
                    grep -q "UUID=$detected_uuid" /etc/fstab 2>/dev/null &&
                        sed -i "\|UUID=$detected_uuid|d" /etc/fstab
                fi

                echo "$fstab_entry" >>/etc/fstab
                ok "Entrée ajoutée"
            fi
        }
        ;;

    2)
        info "Options recommandées par filesystem"
        cat <<'EOF'

ext4:     defaults,noatime
btrfs:    defaults,compress=zstd:3
xfs:      defaults,noatime
vfat/efi: defaults,umask=0022
ntfs-3g:  uid=1000,gid=1000,umask=0022
swap:     defaults

LVM: Utilisez UUID=... ou /dev/mapper/vg-lv (jamais /dev/sdXY)

EOF
        ;;

    3)
        if confirm "Éditer /etc/fstab ?"; then
            ${EDITOR:-nano} /etc/fstab
            ok "Édité"
        fi
        ;;

    4)
        echo
        if command -v findmnt &>/dev/null; then
            findmnt --verify --verbose || warn "Erreurs trouvées"
            echo
        else
            warn "findmnt non disponible"
        fi
        ;;

    5)
        info "Continuer"
        ;;

    *)
        warn "Choix invalide"
        ;;
    esac

    echo
    echo -e "${BLD}▶ Installation du bootloader :${RST}"
    echo

    local _DISTRO_ID _DISTRO_LIKE _BOOTLOADER _IS_EFI _BOOT_DISK
    _DISTRO_ID=$(grep '^ID=' /etc/os-release 2>/dev/null | cut -d'=' -f2 | tr -d '"')
    _DISTRO_LIKE=$(grep '^ID_LIKE=' /etc/os-release 2>/dev/null | cut -d'=' -f2 | tr -d '"')

    _BOOTLOADER=$(efibootmgr 2>/dev/null | grep -i 'BootCurrent:' >/dev/null && echo 'grub' || echo 'unknown')
    _IS_EFI=0
    [[ -d /sys/firmware/efi ]] && _IS_EFI=1
    _BOOT_DISK="$NEW_DISK"

    local _INITRAMFS_CMD _GRUB_MKCONFIG _EFI_DIR

    case "$_DISTRO_ID" in
    fedora | rhel | centos | rocky | almalinux | ol) _INITRAMFS_CMD="dracut -f" ;;
    opensuse | opensuse-leap | sles) _INITRAMFS_CMD="mkinitrd" ;;
    alpine) _INITRAMFS_CMD="mkinitfs" ;;
    void) _INITRAMFS_CMD="xbps-reconfigure -f $(xbps-query -s linux | awk 'NR==1{print $2}' | cut -d- -f1,2)" ;;
    gentoo) _INITRAMFS_CMD="genkernel --install initramfs" ;;
    debian | ubuntu | linuxmint | pop | kali | raspbian) _INITRAMFS_CMD="update-initramfs -u -k all" ;;
    *)
        case "$_DISTRO_LIKE" in
        *arch*) _INITRAMFS_CMD="mkinitcpio -P" ;;
        *debian* | *ubuntu*) _INITRAMFS_CMD="update-initramfs -u -k all" ;;
        esac
        ;;
    esac

    _GRUB_MKCONFIG="grub-mkconfig -o /boot/grub/grub.cfg"
    case "$_DISTRO_ID" in
    debian | ubuntu | linuxmint | pop | kali | raspbian) _GRUB_MKCONFIG="update-grub" ;;
    fedora | rhel | centos | rocky | almalinux | ol | opensuse* | sles)
        _GRUB_MKCONFIG="grub2-mkconfig -o /boot/grub2/grub.cfg"
        ;;
    *)
        case "$_DISTRO_LIKE" in
        *debian* | *ubuntu*) _GRUB_MKCONFIG="update-grub" ;;
        *fedora* | *rhel* | *suse*) _GRUB_MKCONFIG="grub2-mkconfig -o /boot/grub2/grub.cfg" ;;
        esac
        ;;
    esac

    echo -e "  ${BLD}Distro :${RST}     $_DISTRO_ID"
    echo -e "  ${BLD}Bootloader :${RST} $_BOOTLOADER"
    echo -e "  ${BLD}Firmware :${RST}   $([ "$_IS_EFI" -eq 1 ] && echo 'UEFI' || echo 'BIOS/Legacy')"
    echo

    read -rp "$(echo -e "${CYN}▶ /boot est-il sur le VG migré '$VG_NAME' ?${RST} [o/N] ")" _ANS_BOOT
    local _BOOT_ON_VG="n"
    [[ "$_ANS_BOOT" =~ ^[oOyY] ]] && _BOOT_ON_VG="y"

    _EFI_DIR="/boot/efi"
    if test -d /efi/EFI && ! test -d /boot/efi/EFI; then
        _EFI_DIR="/efi"
    fi

    local _EFI_SHARED="n"
    if [ "$_IS_EFI" -eq 1 ] && [ "$_BOOT_ON_VG" = "y" ]; then
        read -rp "$(echo -e "${CYN}▶ La partition EFI est-elle partagée avec un autre disque non migré ?${RST} [o/N] ")" _ANS_EFI
        [[ "$_ANS_EFI" =~ ^[oOyY] ]] && _EFI_SHARED="y"
    fi

    local _EFI_READY="y"
    if [ "$_IS_EFI" -eq 1 ] && [ "$_BOOT_ON_VG" = "y" ] && [ "$_EFI_SHARED" = "n" ]; then
        if ! mountpoint -q "$_EFI_DIR" 2>/dev/null; then
            read -rp "$(echo -e "${CYN}▶ La partition EFI du nouveau disque est-elle déjà créée + montée sur $_EFI_DIR ?${RST} [o/N] ")" _ANS_EFI_READY
            [[ "$_ANS_EFI_READY" =~ ^[oOyY] ]] || _EFI_READY="n"
        fi
    fi

    echo

    if [ "$_BOOT_ON_VG" = "n" ]; then
        echo -e "  ${BLD}✓ /boot est sur un disque séparé — aucune action bootloader requise.${RST}"
        echo
    else
        if [ "$_IS_EFI" -eq 1 ] && [ "$_EFI_READY" = "n" ]; then
            echo -e "  ${BLD}Préparation EFI (création/recréation ESP) :${RST}"
            execute_or_show "parted -s $_BOOT_DISK print free"

            local _EFI_PARTNUM _EFI_PART
            read -rp "$(echo -e "${CYN}Numéro de la partition EFI à créer sur $_BOOT_DISK${RST} (ex: 1) : ")" _EFI_PARTNUM
            [[ -z "$_EFI_PARTNUM" ]] && _EFI_PARTNUM="1"

            execute_or_show "parted -s $_BOOT_DISK mkpart ESP fat32 1MiB 551MiB"
            execute_or_show "parted -s $_BOOT_DISK set $_EFI_PARTNUM esp on"

            read -rp "$(echo -e "${CYN}Chemin de la partition EFI${RST} (ex: /dev/sdb1 ou /dev/nvme0n1p1) : ")" _EFI_PART
            if [[ -n "$_EFI_PART" ]]; then
                execute_or_show "mkfs.vfat -F32 $_EFI_PART"
                execute_or_show "mkdir -p $_EFI_DIR"
                execute_or_show "mount $_EFI_PART $_EFI_DIR"

                local _EFI_UUID
                _EFI_UUID=$(blkid -s UUID -o value "$_EFI_PART" 2>/dev/null || true)
                if [[ -n "$_EFI_UUID" ]]; then
                    execute_or_show "echo 'UUID=$_EFI_UUID  $_EFI_DIR  vfat  umask=0022  0  2' >> /etc/fstab"
                else
                    warn "UUID EFI non détecté — ajoutez l'entrée vfat dans /etc/fstab manuellement."
                fi
            else
                warn "Partition EFI non fournie — la réinstallation UEFI peut échouer."
            fi
            echo
        fi

        if [ "$_BOOTLOADER" = "refind" ]; then
            echo -e "  ${BLD}rEFInd :${RST}"
            if [ "$_EFI_SHARED" = "y" ]; then
                echo -e "    Partition EFI partagée — rEFInd reste accessible, aucune réinstallation requise."
            else
                execute_or_show "refind-install"
            fi
            echo

        elif [ "$_BOOTLOADER" = "systemd-boot" ]; then
            echo -e "  ${BLD}systemd-boot :${RST}"
            if [ "$_EFI_SHARED" = "y" ]; then
                execute_or_show "bootctl status"
            else
                execute_or_show "bootctl install --esp-path=$_EFI_DIR"
                execute_or_show "bootctl update"
                execute_or_show "bootctl status"
            fi
            echo

        elif [ "$_BOOTLOADER" = "grub2" ]; then
            echo -e "  ${BLD}GRUB2 :${RST}"
            if [ "$_IS_EFI" -eq 1 ]; then
                execute_or_show "grub2-install --target=x86_64-efi --efi-directory=$_EFI_DIR --bootloader-id=grub"
            else
                execute_or_show "grub2-install $_BOOT_DISK"
            fi
            execute_or_show "$_GRUB_MKCONFIG"
            execute_or_show "$_INITRAMFS_CMD"
            echo

        elif [ "$_BOOTLOADER" = "grub" ]; then
            echo -e "  ${BLD}GRUB :${RST}"
            if [ "$_IS_EFI" -eq 1 ]; then
                execute_or_show "grub-install --target=x86_64-efi --efi-directory=$_EFI_DIR --bootloader-id=grub"
            else
                execute_or_show "grub-install $_BOOT_DISK"
            fi
            execute_or_show "$_GRUB_MKCONFIG"
            execute_or_show "$_INITRAMFS_CMD"
            echo

        elif [ "$_BOOTLOADER" = "syslinux" ]; then
            echo -e "  ${BLD}syslinux/extlinux :${RST}"
            execute_or_show "extlinux --install /boot/syslinux"
            execute_or_show "dd bs=440 count=1 conv=notrunc if=/usr/lib/syslinux/mbr/mbr.bin of=$_BOOT_DISK"
            echo

        else
            echo -e "  ${BLD}Bootloader non détecté — commandes génériques :${RST}"
            if [ "$_IS_EFI" -eq 1 ]; then
                execute_or_show "grub-install --target=x86_64-efi --efi-directory=$_EFI_DIR --bootloader-id=grub"
            else
                execute_or_show "grub-install $_BOOT_DISK"
            fi
            execute_or_show "$_GRUB_MKCONFIG"
            execute_or_show "$_INITRAMFS_CMD"
            echo
        fi
    fi

    pause
}

# ═══════════════════════════════════════════════════════════════════════════
#  MODULE 9 — SUPPRIMER UN LV
# ═══════════════════════════════════════════════════════════════════════════
remove_lv() {
    title "SUPPRIMER UN LOGICAL VOLUME"

    warn "Opération IRRÉVERSIBLE. Les données seront perdues."
    echo
    echo -e "${BLD}▶ Logical Volumes disponibles :${RST}"
    lvs --noheadings -o lv_path,lv_size,lv_attr 2>/dev/null
    echo

    read -rp "$(echo -e "${CYN}Chemin du LV à supprimer${RST} : ")" LV_PATH
    lvdisplay "$LV_PATH" &>/dev/null || die "LV introuvable."

    confirm "Supprimer DÉFINITIVEMENT $LV_PATH ?" || {
        warn "Annulé."
        return
    }
    confirm "Dernière confirmation — toutes les données seront EFFACÉES ?" || {
        warn "Annulé."
        return
    }

    local lv_attr
    lv_attr=$(lvs --noheadings -o lv_attr "$LV_PATH" | tr -d ' ')
    if [[ "${lv_attr:0:1}" == 'o' ]]; then
        die "LV '$LV_PATH' est ouvert/actif (root ou swap en cours d'utilisation). Abandon."
    fi

    local mount_pt
    mount_pt=$(findmnt -n -o TARGET --source "$LV_PATH" 2>/dev/null || true)
    if [[ -n "$mount_pt" ]]; then
        umount "$LV_PATH" || die "Impossible de démonter (processus actif ?)"
    fi

    lvremove -f "$LV_PATH"
    ok "LV $LV_PATH supprimé."
    pause
}

# ═══════════════════════════════════════════════════════════════════════════
#  MODULE 10 — EXPORTER LE DIAGNOSTIC
# ═══════════════════════════════════════════════════════════════════════════

export_result() {
    title "EXPORTER LE DIAGNOSTIC LVM"

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local default_path="/tmp/lvm-diag_${timestamp}.txt"

    read -rp "$(echo -e "${CYN}Fichier de destination${RST} [${default_path}] : ")" EXPORT_PATH
    [[ -z "$EXPORT_PATH" ]] && EXPORT_PATH="$default_path"

    local export_dir
    export_dir=$(dirname "$EXPORT_PATH")
    [[ -d "$export_dir" ]] || die "Répertoire '$export_dir' introuvable."

    {
        echo "=== LVM DIAGNOSTIC EXPORT ==="
        echo "Date    : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Hôte    : $(hostname -f 2>/dev/null || hostname)"
        echo "Kernel  : $(uname -r)"
        echo "Utilisateur : $(whoami)"
        echo ""

        echo "--- lsblk ---"
        lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,UUID 2>/dev/null || true
        echo ""

        echo "--- Physical Volumes ---"
        pvs -o pv_name,pv_size,pv_free,pv_used,pv_uuid,vg_name 2>/dev/null || true
        echo ""

        echo "--- Physical Volumes (détaillé) ---"
        pvdisplay 2>/dev/null || true
        echo ""

        echo "--- Volume Groups ---"
        vgs -o vg_name,vg_size,vg_free,vg_extent_size,pv_count,lv_count 2>/dev/null || true
        echo ""

        echo "--- Volume Groups (détaillé) ---"
        vgdisplay 2>/dev/null || true
        echo ""

        echo "--- Logical Volumes ---"
        lvs -o lv_path,lv_size,lv_attr,seg_type,origin,data_percent,metadata_percent,copy_percent 2>/dev/null || true
        echo ""

        echo "--- Logical Volumes (détaillé) ---"
        lvdisplay 2>/dev/null || true
        echo ""

        echo "--- blkid ---"
        blkid 2>/dev/null || true
        echo ""

        echo "--- Systèmes de fichiers montés ---"
        df -hT | grep -E "^/dev/mapper|^/dev/[sv]d|Filesystem" || true
        echo ""

        echo "--- Résumé rapide ---"
        local pv_count vg_count lv_count
        pv_count=$(pvs --noheadings 2>/dev/null | grep -c .)
        vg_count=$(vgs --noheadings 2>/dev/null | wc -l)
        lv_count=$(lvs --noheadings 2>/dev/null | wc -l)
        echo "  PV : ${pv_count}   VG : ${vg_count}   LV : ${lv_count}"

        echo "--- ZRAM (swap compressé) ---"
        if lsmod | grep -q zram; then
            echo "Zram actif"
            echo "Algorithmes : $(cat /sys/block/zram0/comp_algorithm 2>/dev/null)"
            for dev in /sys/block/zram*/disksize; do
                if [[ -f "$dev" ]]; then
                    size=$(cat "$dev" 2>/dev/null)
                    name=$(echo "$dev" | cut -d/ -f4)
                    echo "$name : $(numfmt --to=iec "$size" 2>/dev/null || echo "$size")"
                fi
            done
            echo "Swaps :"
            swapon --show | grep -E "zram|NAME"
        else
            echo "Aucun zram actif"
        fi
        echo ""

    } >"$EXPORT_PATH"

    ok "Diagnostic exporté : $EXPORT_PATH"

    echo
    echo -e "  ${BLD}Partage rapide :${RST}"
    echo -e "  ${DIM}scp${RST}      : ${YEL}scp $EXPORT_PATH user@host:/tmp/${RST}"

    if ! command -v curl &>/dev/null; then
        warn "curl absent — installez-le pour activer le partage en ligne."
        pause
        return
    fi

    echo -e "  ${BLD}Service de partage :${RST}"
    echo -e "  ${CYN}1)${RST} dpaste.com       (paste texte, 7 jours)"
    echo -e "  ${CYN}2)${RST} paste.ubuntu.com (paste texte, canonique)"
    echo -e "  ${CYN}3)${RST} GoFile.io        (fichier, téléchargement direct)"
    echo -e "  ${CYN}4)${RST} Aucun"
    echo
    read -rp "$(echo -e "${CYN}Choix${RST} [1-4] : ")" share_choice

    local url
    case "$share_choice" in
    1)
        url=$(curl -s --max-time 20 \
            -X POST https://dpaste.com/api/v2/ \
            --data-urlencode "content@${EXPORT_PATH}" \
            -d "syntax=text" -d "expiry_days=7" | tr -d '"' || true)
        if [[ "$url" == https* ]]; then
            ok "dpaste.com : $url"
        else
            warn "Envoi dpaste échoué."
        fi
        ;;
    2)
        url=$(curl -s --max-time 20 \
            -F "poster=lvm-manager" -F "syntax=text" \
            -F "expiration=week" -F "content=<${EXPORT_PATH}" \
            https://paste.ubuntu.com/ \
            -w "%{url_effective}" -o /dev/null || true)
        if [[ "$url" == https://paste.ubuntu.com/* ]]; then
            ok "paste.ubuntu.com : $url"
        else
            warn "Envoi paste.ubuntu échoué."
        fi
        ;;
    3)
        local server token file_url
        server=$(curl -s --max-time 10 https://api.gofile.io/servers |
            grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
        if [[ -z "$server" ]]; then
            warn "GoFile : impossible de joindre l'API."
            return 1
        fi
        token=$(curl -s --max-time 10 https://api.gofile.io/accounts |
            grep -o '"token":"[^"]*"' | cut -d'"' -f4 || true)
        file_url=$(curl -s --max-time 30 \
            -F "file=@${EXPORT_PATH}" \
            -F "token=${token}" \
            "https://${server}.gofile.io/uploadFile" |
            grep -o '"downloadPage":"[^"]*"' | cut -d'"' -f4 || true)
        if [[ -n "$file_url" ]]; then
            ok "GoFile.io : $file_url"
        else
            warn "Envoi GoFile échoué."
        fi
        ;;
    4)
        info "Partage annulé."
        ;;
    *)
        warn "Choix invalide."
        ;;
    esac

    pause
}

# ═══════════════════════════════════════════════════════════════════════════
#  MODULE 11 — GESTION DU SWAP (LVM)
# ═══════════════════════════════════════════════════════════════════════════
manage_swap() {
    while true; do
        title "GESTION DU SWAP SUR LVM"

        echo -e "  ${BLD}0)${RST} Retour au menu principal"
        echo -e "  ${BLD}1)${RST} Afficher les swaps actifs"
        echo -e "  ${BLD}2)${RST} Créer un LV swap"
        echo -e "  ${BLD}3)${RST} Étendre un LV swap (à chaud)"
        echo -e "  ${BLD}4)${RST} Réduire un LV swap (désactivé requis)"
        echo -e "  ${BLD}5)${RST} Déplacer un LV swap vers un autre VG (à chaud)"
        echo -e "  ${BLD}6)${RST} Supprimer un LV swap"
        echo -e "  ${BLD}7)${RST} Créer un swap mutualisé pour plusieurs OS"
        echo
        read -rp "$(echo -e "${CYN}Choix${RST} [0-7] : ")" swap_action

        case "$swap_action" in
        0)
            return
            ;;

        1)
            echo -e "\n${BLD}▶ Swaps actifs :${RST}"
            sep
            swapon --show 2>/dev/null || echo "Aucun swap actif"
            echo
            echo -e "${BLD}▶ LV avec type swap :${RST}"
            lvs -o lv_path,lv_size,lv_attr -S "lv_layout=swap" 2>/dev/null || echo "Aucun LV swap trouvé"
            ;;

        2)
            echo -e "\n${BLD}▶ Volume Groups disponibles :${RST}"
            vgs --noheadings -o vg_name,vg_size,vg_free 2>/dev/null
            echo
            read -rp "$(echo -e "${CYN}VG cible${RST} : ")" VG_SWAP
            vgs "$VG_SWAP" &>/dev/null || die "VG '$VG_SWAP' introuvable"

            read -rp "$(echo -e "${CYN}Nom du LV swap${RST} (ex: swap_vol) : ")" LV_SWAP_NAME
            [[ -z "$LV_SWAP_NAME" ]] && die "Nom vide"

            read -rp "$(echo -e "${CYN}Taille${RST} (ex: 2G, 4G) : ")" SWAP_SIZE
            [[ -z "$SWAP_SIZE" ]] && die "Taille vide"

            confirm "Créer /dev/$VG_SWAP/$LV_SWAP_NAME de taille $SWAP_SIZE ?" || return

            lvcreate -L "$SWAP_SIZE" -n "$LV_SWAP_NAME" "$VG_SWAP"
            mkswap "/dev/$VG_SWAP/$LV_SWAP_NAME"
            ok "LV swap créé : /dev/$VG_SWAP/$LV_SWAP_NAME"

            if confirm "Activer le swap maintenant ?"; then
                swapon "/dev/$VG_SWAP/$LV_SWAP_NAME"
                ok "Swap activé"
            fi

            if confirm "Ajouter à /etc/fstab (montage permanent) ?"; then
                local uuid
                uuid=$(blkid -s UUID -o value "/dev/$VG_SWAP/$LV_SWAP_NAME")
                echo "UUID=$uuid  none  swap  sw  0  0" >>/etc/fstab
                ok "Entrée ajoutée dans /etc/fstab (UUID: $uuid)"
            fi
            ;;

        3)
            echo -e "\n${BLD}▶ LV swap disponibles :${RST}"
            lvs -o lv_path,lv_size -S "lv_layout=swap" 2>/dev/null || die "Aucun LV swap trouvé"
            echo
            read -rp "$(echo -e "${CYN}LV swap à étendre${RST} : ")" SWAP_LV
            lvdisplay "$SWAP_LV" &>/dev/null || die "LV '$SWAP_LV' introuvable"

            local vg_name
            vg_name=$(lvs --noheadings -o vg_name "$SWAP_LV" | tr -d ' ')
            local vg_free
            vg_free=$(vgs --noheadings --units g -o vg_free "$vg_name" | tr -d ' g')
            info "Espace libre dans $vg_name : ${vg_free}G"

            read -rp "$(echo -e "${CYN}Nouvelle taille${RST} (ex: 4G, +2G) : ")" NEW_SIZE

            # Désactiver temporairement si actif
            local was_active=false
            if swapon --show | grep -q "$SWAP_LV"; then
                warn "Swap actif détecté — désactivation temporaire..."
                swapoff "$SWAP_LV"
                was_active=true
                ok "Swap désactivé"
            fi

            info "Extension du LV swap..."
            if [[ "$NEW_SIZE" == +* ]]; then
                lvextend -L "$NEW_SIZE" "$SWAP_LV"
            else
                lvextend -L "$NEW_SIZE" "$SWAP_LV"
            fi

            # Réinitialiser le swap (nécessaire après extension)
            mkswap "$SWAP_LV"
            ok "Swap étendu et reformaté"

            if [[ "$was_active" == true ]]; then
                swapon "$SWAP_LV"
                ok "Swap réactivé"
            fi

            lvs "$SWAP_LV"
            ;;

        4)
            echo -e "\n${BLD}▶ LV swap disponibles :${RST}"
            lvs -o lv_path,lv_size -S "lv_layout=swap" 2>/dev/null || die "Aucun LV swap trouvé"
            echo
            read -rp "$(echo -e "${CYN}LV swap à réduire${RST} : ")" SWAP_LV

            # Vérifier et désactiver
            if swapon --show | grep -q "$SWAP_LV"; then
                swapoff "$SWAP_LV"
                ok "Swap désactivé"
            else
                info "Swap déjà inactif"
            fi

            read -rp "$(echo -e "${CYN}Nouvelle taille${RST} (ex: 2G) : ")" NEW_SIZE

            # Vérifier la taille (ne pas réduire en dessous de ce qui est utilisé)
            warn "Réduction destructive — le swap sera reformaté après réduction"
            confirm "Continuer ?" || return

            lvreduce -L "$NEW_SIZE" "$SWAP_LV"
            mkswap "$SWAP_LV"
            ok "Swap réduit et reformaté"

            if confirm "Réactiver le swap ?"; then
                swapon "$SWAP_LV"
                ok "Swap réactivé"
            fi
            ;;

        5)
            echo -e "\n${BLD}▶ Déplacer un LV swap vers un autre VG (à chaud)${RST}"
            echo
            echo -e "${BLD}▶ LV swap disponibles :${RST}"
            lvs -o lv_path,lv_size,vg_name -S "lv_layout=swap" 2>/dev/null || die "Aucun LV swap trouvé"
            echo
            read -rp "$(echo -e "${CYN}LV swap à déplacer${RST} : ")" SWAP_LV
            lvdisplay "$SWAP_LV" &>/dev/null || die "LV introuvable"

            echo -e "\n${BLD}▶ VG disponibles :${RST}"
            vgs -o vg_name,vg_size,vg_free 2>/dev/null
            echo
            read -rp "$(echo -e "${CYN}VG de destination${RST} : ")" DST_VG
            vgs "$DST_VG" &>/dev/null || die "VG '$DST_VG' introuvable"

            local current_vg
            current_vg=$(lvs --noheadings -o vg_name "$SWAP_LV" | tr -d ' ')
            local lv_name
            lv_name=$(basename "$SWAP_LV")
            local lv_size
            lv_size=$(lvs --noheadings --units g -o lv_size "$SWAP_LV" | tr -d ' ' | sed 's/g//i')
            if [[ "$current_vg" == "$DST_VG" ]]; then
                die "Le VG de destination ($DST_VG) est identique au VG source. Déplacement inutile."
            fi

            confirm "Déplacer $SWAP_LV ($lv_size G) vers $DST_VG ?" || return

            # Désactiver swap
            local was_active=false
            if swapon --show | grep -q "$SWAP_LV"; then
                swapoff "$SWAP_LV"
                was_active=true
                ok "Swap désactivé"
            fi

            # Méthode : créer nouveau LV, copier les données (mkswap = nouveau format)
            local new_lv_path="/dev/$DST_VG/$lv_name"
            info "Création du nouveau LV swap : $new_lv_path"
            lvcreate -L "${lv_size}G" -n "$lv_name" "$DST_VG"
            mkswap "$new_lv_path"

            # Mettre à jour fstab
            local old_uuid new_uuid
            old_uuid=$(blkid -s UUID -o value "$SWAP_LV")
            new_uuid=$(blkid -s UUID -o value "$new_lv_path")

            if [[ -f /etc/fstab ]] && grep -q "$old_uuid" /etc/fstab; then
                sed -i "s/$old_uuid/$new_uuid/g" /etc/fstab
                ok "/etc/fstab mis à jour"
            elif [[ -f /etc/fstab ]] && grep -q "$SWAP_LV" /etc/fstab; then
                sed -i "s|$SWAP_LV|$new_lv_path|g" /etc/fstab
                ok "/etc/fstab mis à jour"
            fi

            # Activer nouveau swap
            if [[ "$was_active" == true ]]; then
                swapon "$new_lv_path"
                ok "Nouveau swap activé"
            fi

            # Supprimer l'ancien
            lvremove -f "$SWAP_LV"
            ok "Ancien swap supprimé"

            echo -e "\n${GRN}Swap déplacé : $new_lv_path${RST}"
            lvs "$new_lv_path"
            ;;

        6)
            echo -e "\n${BLD}▶ LV swap disponibles :${RST}"
            lvs -o lv_path,lv_size -S "lv_layout=swap" 2>/dev/null || die "Aucun LV swap trouvé"
            echo
            read -rp "$(echo -e "${CYN}LV swap à supprimer${RST} : ")" SWAP_LV

            # Désactiver si actif
            if swapon --show | grep -q "$SWAP_LV"; then
                swapoff "$SWAP_LV"
                ok "Swap désactivé"
            fi

            # Retirer de fstab
            local uuid
            uuid=$(blkid -s UUID -o value "$SWAP_LV" 2>/dev/null)
            if [[ -f /etc/fstab ]] && [[ -n "$uuid" ]] && grep -q "$uuid" /etc/fstab; then
                sed -i "/$uuid/d" /etc/fstab
                ok "Entrée supprimée de /etc/fstab"
            elif [[ -f /etc/fstab ]] && grep -q "$SWAP_LV" /etc/fstab; then
                sed -i "\|$SWAP_LV|d" /etc/fstab
                ok "Entrée supprimée de /etc/fstab"
            fi

            confirm "Supprimer définitivement $SWAP_LV ?" || return
            lvremove -f "$SWAP_LV"
            ok "Swap supprimé"
            ;;
        7)
            echo -e "\n${BLD}▶ Créer un swap mutualisé pour plusieurs OS${RST}"
            echo -e "  ${DIM}Utile quand plusieurs distribs partagent le même disque/SSD${RST}"
            echo
            echo -e "  ${BLD}Principe :${RST}"
            echo "    - Un seul LV swap créé"
            echo "    - Tous les OS l'utilisent (même UUID)"
            echo "    - Un seul OS à la fois peut l'activer (risque sinon)"
            echo
            echo -e "${BLD}▶ Volume Groups disponibles :${RST}"
            vgs -o vg_name,vg_size,vg_free
            echo
            read -rp "$(echo -e "${CYN}VG cible${RST} (où créer le swap commun) : ")" VG_SHARED
            vgs "$VG_SHARED" &>/dev/null || die "VG '$VG_SHARED' introuvable"

            read -rp "$(echo -e "${CYN}Nom du LV swap${RST} (ex: swap_shared) : ")" SWAP_NAME
            [[ -z "$SWAP_NAME" ]] && SWAP_NAME="swap_shared"

            read -rp "$(echo -e "${CYN}Taille${RST} (ex: 4G, 8G) : ")" SWAP_SIZE
            [[ -z "$SWAP_SIZE" ]] && die "Taille vide"

            confirm "Créer /dev/$VG_SHARED/$SWAP_NAME (taille $SWAP_SIZE)" || return

            lvcreate -L "$SWAP_SIZE" -n "$SWAP_NAME" "$VG_SHARED"
            mkswap "/dev/$VG_SHARED/$SWAP_NAME"

            local SWAP_UUID
            SWAP_UUID=$(blkid -s UUID -o value "/dev/$VG_SHARED/$SWAP_NAME")

            ok "Swap créé : /dev/$VG_SHARED/$SWAP_NAME (UUID: $SWAP_UUID)"
            echo
            echo -e "${BLD}▶ Pour chaque OS, ajouter dans /etc/fstab :${RST}"
            echo -e "  ${DIM}UUID=$SWAP_UUID  none  swap  sw  0  0${RST}"
            echo
            warn "⚠  Attention : Un seul OS à la fois peut activer ce swap"
            echo "   Si deux OS bootent ensemble, corruption garantie"
            ;;
        *)
            warn "Choix invalide"
            ;;
        esac
        pause
    done
}
# ═══════════════════════════════════════════════════════════════════════════
#  MODULE 11.5 — SWAP MUTUALISÉ
# ═══════════════════════════════════════════════════════════════════════════
manage_swap_mutualized() {
    title "MUTUALISER TOUS LES SWAPS EN UN SEUL"

    # 1. Afficher les VG disponibles
    echo -e "${BLD}▶ Volume Groups disponibles :${RST}"
    vgs -o vg_name,vg_size,vg_free
    echo

    # 2. Scanner tous les swaps actifs (zram + lvswap + partitions)
    echo -e "${BLD}▶ Swaps détectés sur ce système :${RST}"
    swapon --show 2>/dev/null || echo "  Aucun swap actif"
    lvs -o lv_path,lv_size,vg_name -S "lv_layout=swap" 2>/dev/null || echo "  Aucun LV swap"
    cat /proc/swaps 2>/dev/null | head -10
    echo

    # 3. Détecter les autres OS (partitions avec /etc/fstab)
    echo -e "\n${BLD}▶ Autres systèmes détectés :${RST}"
    for part in $(lsblk -o MOUNTPOINT -l | grep -v "^$" | grep -v "^/$"); do
        if [[ -f "$part/etc/fstab" ]]; then
            echo "  OS trouvé sur : $part"
        fi
    done
    echo

    # 4. Demander confirmation
    warn "⚠ Cette opération va :"
    echo "   - Désactiver TOUS les swaps"
    echo "   - Supprimer TOUS les LV swap existants"
    echo "   - Créer un UNIQUE swap mutualisé"
    echo "   - Mettre à jour TOUS les /etc/fstab trouvés"
    echo
    confirm "Continuer ?" || return

    # 5. Désactiver tous les swaps
    info "Désactivation de TOUS les swaps..."
    swapoff -a 2>/dev/null
    ok "Swaps désactivés"

    # 6. Supprimer les anciens LV swap
    info "Suppression des anciens LV swap..."
    for old_swap in $(lvs -o lv_path -S "lv_layout=swap" --noheadings 2>/dev/null); do
        echo "  Suppression : $old_swap"
        lvremove -f "$old_swap" 2>/dev/null
    done
    ok "Anciens LV swap supprimés"

    # 7. Créer le nouveau swap unique
    echo -e "${BLD}▶ Volume Groups disponibles :${RST}"
    vgs -o vg_name,vg_size,vg_free
    echo
    read -rp "$(echo -e "${CYN}VG pour le swap mutualisé${RST} : ")" VG_MUTUAL
    vgs "$VG_MUTUAL" &>/dev/null || die "VG '$VG_MUTUAL' introuvable"

    local total_ram
    total_ram=$(free -b | grep Mem | awk '{print $2}')
    local default_size=$((total_ram / 2))
    echo -e "  Taille recommandée : $(numfmt --to=iec $default_size) (50% de la RAM)"
    read -rp "$(echo -e "${CYN}Taille${RST} (ex: 4G, 8G) : ")" SWAP_SIZE
    [[ -z "$SWAP_SIZE" ]] && SWAP_SIZE="$(numfmt --to=iec $default_size)"

    info "Création du swap mutualisé..."
    lvcreate -L "$SWAP_SIZE" -n "swap_mutualized" "$VG_MUTUAL"
    mkswap "/dev/$VG_MUTUAL/swap_mutualized"
    SWAP_UUID=$(blkid -s UUID -o value "/dev/$VG_MUTUAL/swap_mutualized")
    ok "Swap créé : /dev/$VG_MUTUAL/swap_mutualized (UUID: $SWAP_UUID)"

    # 8. Mettre à jour fstab de TOUS les OS
    info "Mise à jour des /etc/fstab..."

    find / -name "fstab" -path "*/etc/fstab" \
        -not -path "*/proc/*" \
        -not -path "*/sys/*" \
        -not -path "*/dev/*" \
        -not -path "*/run/*" 2>/dev/null |
        while IFS= read -r fstab; do
            echo "  Mise à jour : $fstab"
            cp "$fstab" "$fstab.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null
            sed -i '/swap/d' "$fstab" 2>/dev/null
            echo "UUID=$SWAP_UUID  none  swap  sw  0  0" >>"$fstab"
        done

    ok "Fichiers fstab mis à jour"

    # 9. Activer le nouveau swap
    swapon "/dev/$VG_MUTUAL/swap_mutualized"
    ok "Swap mutualisé activé"

    # 10. Résumé final
    echo
    sep
    echo -e "${GRN}✓ Migration terminée !${RST}"
    echo -e "  Nouveau swap : /dev/$VG_MUTUAL/swap_mutualized"
    echo -e "  UUID : $SWAP_UUID"
    echo -e "  Taille : $SWAP_SIZE"
    swapon --show | grep -E "NAME|swap_mutualized" || true

    pause
}

# ═══════════════════════════════════════════════════════════════════════════
#  MODULE 12 — GESTION ZRAM (swap compressé en RAM)
# ═══════════════════════════════════════════════════════════════════════════
manage_zram() {
    while true; do
        title "GESTION ZRAM (swap compressé en RAM)"

        echo -e "  ${BLD}0)${RST} Retour au menu principal"
        echo -e "  ${BLD}1)${RST} Afficher l'état actuel de zram"
        echo -e "  ${BLD}2)${RST} Installer/configurer zram (permanent)"
        echo -e "  ${BLD}3)${RST} Modifier l'algorithme de compression (lzo/lz4/zstd)"
        echo -e "  ${BLD}4)${RST} Modifier la taille du zram (à chaud, temporaire)"
        echo -e "  ${BLD}5)${RST} Désactiver/arrêter zram"
        echo -e "  ${BLD}6)${RST} Réactiver zram"
        echo
        read -rp "$(echo -e "${CYN}Choix${RST} [0-7] : ")" zram_action

        case "$zram_action" in
        0) return ;;
        1)
            echo -e "\n${BLD}▶ Périphériques zram :${RST}"
            sep
            lsblk | grep zram || echo "Aucun zram détecté"
            echo
            echo -e "${BLD}▶ Swaps actifs (dont zram) :${RST}"
            swapon --show | grep -E "zram|NAME" || echo "Aucun swap zram actif"
            echo
            echo -e "${BLD}▶ Algorithmes disponibles :${RST}"
            cat /sys/block/zram0/comp_algorithm 2>/dev/null || echo "Zram non chargé"
            echo
            echo -e "${BLD}▶ Taille actuelle :${RST}"
            for dev in /sys/block/zram*/disksize; do
                if [[ -f "$dev" ]]; then
                    size=$(cat "$dev" 2>/dev/null)
                    name=$(echo "$dev" | cut -d/ -f4)
                    echo "  $name : $(numfmt --to=iec "$size" 2>/dev/null || echo "$size")"
                fi
            done
            ;;

        2)
            echo -e "\n${BLD}▶ Installation/configuraton permanente de zram${RST}"

            # Détection distrib
            if command -v apt-get &>/dev/null; then
                info "Installation zram-tools (Debian/Ubuntu)..."
                apt-get install -y zram-tools
                ZRAM_CONF="/etc/default/zramswap"
                ZRAM_SERVICE="zramswap"
            elif command -v dnf &>/dev/null; then
                info "Installation zram-generator (Fedora/RHEL/Rocky)..."
                dnf install -y zram-generator
                ZRAM_CONF="/etc/zram-generator.conf"
                ZRAM_SERVICE="systemd-zram-setup@zram0"
            else
                die "Distribution non supportée pour l'installation auto de zram"
            fi

            if [[ -f "$ZRAM_CONF" ]]; then
                info "Fichier de conf existant : $ZRAM_CONF"
            else
                info "Création de la configuration par défaut..."
            fi

            # Proposer taille et algo
            local total_ram
            total_ram=$(free -b | awk '/^Mem:/ {print $2}')
            local default_size=$((total_ram / 2))
            echo -e "\n  RAM totale : $(numfmt --to=iec "$total_ram")"
            echo -e "  Taille zram recommandée : 50% soit $(numfmt --to=iec "$default_size")"
            read -rp "$(echo -e "${CYN}Taille du zram${RST} (ex: 2G, 4096M, laisser vide pour 50%) : ")" ZRAM_SIZE
            [[ -z "$ZRAM_SIZE" ]] && ZRAM_SIZE="$(numfmt --to=iec "$default_size")"

            # Convertir en megabytes pour zram-tools
            local ZRAM_SIZE_MB
            local size_upper="${ZRAM_SIZE^^}"
            if [[ "$size_upper" =~ G$ ]]; then
                ZRAM_SIZE_MB=$((${size_upper%G} * 1024))
            elif [[ "$size_upper" =~ M$ ]]; then
                ZRAM_SIZE_MB="${size_upper%M}"
            else
                ZRAM_SIZE_MB=$((ZRAM_SIZE / 1024 / 1024))
            fi

            echo -e "\n  ${BLD}Algorithmes disponibles :${RST}"
            echo -e "  lzo   (rapide, bonne compression)"
            echo -e "  lz4   (très rapide, compression moyenne)"
            echo -e "  zstd  (bonne compression, un peu plus lent)"
            echo -e "  lzo-rle (variante de lzo)"
            read -rp "$(echo -e "${CYN}Algorithme${RST} [lz4 par défaut] : ")" ZRAM_ALGO
            [[ -z "$ZRAM_ALGO" ]] && ZRAM_ALGO="lz4"
            if command -v apt-get &>/dev/null; then
                cat >"$ZRAM_CONF" <<EOF
# zram-tools configuration
PERCENT=50
SIZE=$ZRAM_SIZE_MB
ALGO=$ZRAM_ALGO
PRIORITY=100
EOF
                systemctl enable --now "$ZRAM_SERVICE"
                ok "Zram configuré et activé"
            elif command -v dnf &>/dev/null; then
                cat >"$ZRAM_CONF" <<EOF
[zram0]
zram-size = $ZRAM_SIZE
compression-algorithm = $ZRAM_ALGO
swap-priority = 100
EOF
                systemctl enable --now "$ZRAM_SERVICE"
                ok "Zram configuré et activé"
            fi
            ;;

        3)
            echo -e "\n${BLD}▶ Modifier l'algorithme de compression${RST}"

            # Vérifier si zram actif
            if ! lsmod | grep -q zram; then
                warn "Zram non chargé. Installez/activez d'abord (option 2)"
                return
            fi

            echo -e "\n${BLD}Algorithmes supportés par le noyau :${RST}"
            cat /sys/block/zram0/comp_algorithm 2>/dev/null || die "Impossible de lire les algorithmes"

            echo -e "\n  ${BLD}Algorithmes disponibles :${RST}"
            echo -e "  lzo   (rapide)"
            echo -e "  lz4   (très rapide)"
            echo -e "  zstd  (meilleur ratio)"

            echo "  lzo-rle"
            read -rp "$(echo -e "${CYN}Nouvel algorithme${RST} : ")" NEW_ALGO

            # Pour changer à chaud, il faut réinitialiser zram
            warn "Changement d'algorithme nécessite la désactivation du swap zram"
            confirm "Continuer ?" || return

            # Désactiver tous les zram
            for dev in /dev/zram*; do
                [[ -b "$dev" ]] && swapoff "$dev" 2>/dev/null
            done
            rmmod zram
            modprobe zram

            # Réactiver avec le nouvel algo
            echo "$NEW_ALGO" >/sys/block/zram0/comp_algorithm 2>/dev/null || die "Algorithme non supporté"

            # Reconfigurer taille (récupérer l'ancienne config)
            local old_size
            old_size=$(cat /sys/block/zram0/disksize 2>/dev/null || echo "1G")
            info "Ancienne taille: $(numfmt --to=iec "$old_size" 2>/dev/null || echo "$old_size")"

            if command -v apt-get &>/dev/null && [[ -f /etc/default/zramswap ]]; then
                sed -i "s/^ALGO=.*/ALGO=$NEW_ALGO/" /etc/default/zramswap
                ok "Persistance : ALGO mis à jour dans /etc/default/zramswap"
            elif command -v dnf &>/dev/null && [[ -f /etc/zram-generator.conf ]]; then
                sed -i "s/^compression-algorithm = .*/compression-algorithm = $NEW_ALGO/" /etc/zram-generator.conf
                ok "Persistance : compression-algorithm mis à jour dans /etc/zram-generator.conf"
            else
                warn "Fichier de config non trouvé — changement temporaire uniquement (reboot le réinitialisera)"
            fi

            ok "Algorithme changé pour $NEW_ALGO"
            ;;

        4)
            echo -e "\n${BLD}▶ Modifier la taille du zram (temporaire)${RST}"

            if ! lsmod | grep -q zram; then
                die "Zram non chargé"
            fi

            local current_size
            current_size=$(cat /sys/block/zram0/disksize 2>/dev/null)
            info "Taille actuelle : $(numfmt --to=iec "$current_size" 2>/dev/null)"

            read -rp "$(echo -e "${CYN}Nouvelle taille${RST} (ex: 2G, 4096M) : ")" ZRAM_NEW_SIZE

            warn "Changement de taille nécessite désactivation"
            confirm "Continuer ?" || return

            # Désactiver zram
            for dev in /dev/zram*; do
                [[ -b "$dev" ]] && swapoff "$dev" 2>/dev/null
            done

            # Reconfigurer taille
            echo 1 >/sys/block/zram0/reset 2>/dev/null
            echo "$ZRAM_NEW_SIZE" >/sys/block/zram0/disksize

            # Réactiver
            mkswap /dev/zram0
            swapon /dev/zram0 -p 100

            ok "Taille modifiée : $ZRAM_NEW_SIZE"
            swapon --show | grep zram
            ;;

        5)
            echo -e "\n${BLD}▶ Désactiver/arrêter zram${RST}"
            confirm "Désactiver tous les périphériques zram ?" || return

            for dev in /dev/zram*; do
                [[ -b "$dev" ]] && swapoff "$dev" 2>/dev/null
            done
            rmmod zram 2>/dev/null
            ok "Zram désactivé"

            if command -v systemctl &>/dev/null; then
                systemctl stop zramswap 2>/dev/null
                systemctl stop systemd-zram-setup@zram0 2>/dev/null
            fi
            ;;

        6)
            echo -e "\n${BLD}▶ Réactiver zram${RST}"

            if command -v systemctl &>/dev/null; then
                systemctl start zramswap 2>/dev/null ||
                    systemctl start systemd-zram-setup@zram0 2>/dev/null ||
                    warn "Service non trouvé, activation manuelle..."
            fi

            # Activation manuelle si service absent
            if ! lsmod | grep -q zram; then
                modprobe zram
                echo "lz4" >/sys/block/zram0/comp_algorithm
                echo "1G" >/sys/block/zram0/disksize
                mkswap /dev/zram0
                swapon /dev/zram0 -p 100
                ok "Zram réactivé manuellement (taille 1G, algo lz4)"
            else
                ok "Zram déjà actif"
            fi
            swapon --show | grep zram
            ;;

        *)
            warn "Choix invalide"
            ;;
        esac
        pause
    done
}

# ─── Utilitaires ───────────────────────────────────────────────────────────
pause() {
    echo
    read -rp "$(echo -e "${DIM}  Appuyez sur Entrée pour continuer...${RST}")" _
}

# ═══════════════════════════════════════════════════════════════════════════
#  MENU PRINCIPAL
# ═══════════════════════════════════════════════════════════════════════════
main_menu() {
    while true; do
        banner
        echo -e "  ${BLD}MENU PRINCIPAL${RST}\n"
        echo -e "  ${CYN}1)${RST}  Diagnostic complet (état LVM)"
        echo -e "  ${CYN}2)${RST}  Créer un Logical Volume"
        echo -e "  ${CYN}3)${RST}  Étendre un LV + redimensionner FS  ${DIM}(à chaud)${RST}"
        echo -e "  ${CYN}4)${RST}  Réduire un LV                      ${DIM}(ext4, démontage requis)${RST}"
        echo -e "  ${CYN}5)${RST}  Déplacer des données (pvmove)       ${DIM}(à chaud, online)${RST}"
        echo -e "  ${CYN}6)${RST}  Snapshots LVM"
        echo -e "  ${CYN}7)${RST}  Ajouter un disque / étendre un VG"
        echo -e "  ${CYN}8)${RST}  Migrer l'OS vers un nouveau disque  ${DIM}(à chaud)${RST}"
        echo -e "  ${CYN}9)${RST}  Supprimer un LV"
        echo -e "  ${CYN}e)${RST}  Exporter le diagnostic"
        echo -e "  ${CYN}s)${RST}  Gestion du Swap (LVM)"
        echo -e "  ${CYN}z)${RST}  Gestion ZRAM (swap compressé)"
        echo -e "  ${CYN}q)${RST}  Quitter"
        echo
        sep
        read -rp "$(echo -e "  ${BLD}Votre choix${RST} : ")" choice
        echo

        case "$choice" in
        1) diag_full ;;
        2) create_lv ;;
        3) extend_lv ;;
        4) shrink_lv ;;
        5) pvmove_data ;;
        6) snapshot_lv ;;
        7) add_disk_to_vg ;;
        8) migrate_os ;;
        9) remove_lv ;;
        e | E) export_result ;;
        s | S) manage_swap ;;
        z | Z) manage_zram ;;
        q | Q | quit | exit)
            echo -e "\n${GRN}Au revoir !${RST}\n"
            exit 0
            ;;
        *)
            warn "Choix invalide : '$choice'"
            sleep 1
            ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════════════════
#  POINT D'ENTRÉE
# ═══════════════════════════════════════════════════════════════════════════
check_root
check_deps
main_menu
