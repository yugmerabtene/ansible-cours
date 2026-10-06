#!/usr/bin/env bash
# ===========================================================================
# 10-preparer-vm.sh — Préparation d'une VM du lab Ansible (à exécuter en root)
#
# Où l'exécuter : DANS la VM vierge à préparer, une fois Ubuntu Server
# installé, depuis la console de l'installateur ou depuis un accès SSH direct
# au compte de l'installateur. En situation de cours, la seule VM à préparer
# est le node web1, livré vierge :
#   sudo labs/scripts/10-preparer-vm.sh --nom web1 --ip 172.16.0.11
#
# Le control node cn-ansible est livré déjà équipé (nom d'hôte, adresse
# statique, compte stagiaire, clé SSH, entrées /etc/hosts). Par mesure de
# protection, ce script le refuse par défaut : préparer un control node
# reconstruit de zéro exige l'option explicite --control-node, qui ne
# supprime aucun équipement existant (toutes les étapes sont idempotentes).
#
# Ce que fait le script, dans cet ordre :
#   1. vérifie les paramètres (nom connu, adresse cohérente) et les prérequis ;
#   2. fixe le nom d'hôte de la machine ;
#   3. écrit la configuration réseau statique du lab depuis le gabarit
#      templates/99-lab.yaml (interface du réseau privé détectée) ;
#   4. maintient une configuration DHCP sur l'interface NAT si l'installateur
#      n'en fournit pas (accès Internet conservé) ;
#   5. désactive la configuration réseau gérée par cloud-init ;
#   6. installe openssh-server et python3 (prérequis Ansible des nodes) ;
#   7. crée le compte stagiaire (uid 1001) avec un sudo sans mot de passe ;
#   8. écrit les deux entrées /etc/hosts du lab dans un bloc géré ;
#   9. applique la configuration réseau avec netplan et vérifie l'adresse.
#
# Idempotence : le script peut être relancé autant de fois que nécessaire.
# Un second passage ne modifie que ce qui a réellement changé et annonce
# explicitement les fichiers inchangés.
#
# Sécurité : réservé au lab de formation isolé (172.16.0.0/24). Le compte
# stagiaire obtient un sudo sans mot de passe : ne jamais utiliser cette
# méthode sur une machine de production.
# ===========================================================================
set -euo pipefail

# --- Contrat d'adressage du lab (non négociable) -----------------------------
readonly -a NOMS_VM=("cn-ansible" "web1")
readonly -a IPS_VM=("172.16.0.10" "172.16.0.11")
readonly NOM_CONTROL_NODE="cn-ansible"  # control node livré déjà équipé
readonly PREFIXE_RESEAU="172.16.0" # début des adresses du lab, utilisé pour la détection

# --- Compte du lab -----------------------------------------------------------
readonly UTILISATEUR_LAB="stagiaire"  # compte utilisé par Ansible et par SSH
readonly UID_LAB=1001                 # identifiant fixe du compte, identique sur les deux VM
readonly GROUPE_SUDO="sudo"           # groupe d'administration du lab
readonly COQUILLE="/bin/bash"

# --- Fichiers gérés par le script -------------------------------------------
readonly CHEMIN_NETPLAN="/etc/netplan/99-lab.yaml"       # adressage statique du réseau privé
readonly CHEMIN_NETPLAN_NAT="/etc/netplan/98-nat-dhcp.yaml" # DHCP de secours sur l'interface NAT
readonly CHEMIN_CLOUD_INIT="/etc/cloud/cloud.cfg.d/00-subiquity-disable-cloudinit-networking.cfg"
readonly CHEMIN_SUDOERS="/etc/sudoers.d/99-stagiaire"
readonly FICHIER_HOSTS="/etc/hosts"
readonly MARQUEUR_DEBUT="# LAB-ANSIBLE-DEBUT"  # début du bloc /etc/hosts géré par le script
readonly MARQUEUR_FIN="# LAB-ANSIBLE-FIN"      # fin du bloc /etc/hosts géré par le script

# --- Valeurs techniques ------------------------------------------------------
readonly PAQUETS_LAB="openssh-server python3"  # serveur SSH et Python : prérequis des nodes Ansible
readonly DROITS_NETPLAN="600"   # netplan refuse un fichier de configuration lisible par tous
readonly DROITS_CLOUD_INIT="644"
readonly DROITS_SUDOERS="440"   # sudo refuse un fichier de règles trop permissif
readonly DROITS_HOSTS="644"
readonly ATTENTE_ADRESSE=15     # secondes accordées à l'apparition de l'adresse après netplan apply
readonly SERVICE_SSH_DEBIAN="ssh"  # nom du service sur Debian et Ubuntu
readonly SERVICE_SSH_RHEL="sshd"   # nom du service sur Rocky et RHEL

# --- Valeurs par défaut (modifiables par les options de la ligne de commande) -
NOM=""          # nom de la machine : web1 (cas normal) ou cn-ansible (--control-node)
ADRESSE_IP=""   # adresse IPv4 statique de la machine sur le réseau privé
INTERFACE_FORCEE=""  # interface du réseau privé à utiliser si la détection échoue
MASQUE_LAB=24   # longueur du préfixe du réseau privé (option --masque)
INSTALLER_PAQUETS="oui"  # installer openssh-server et python3 (option --sans-paquets)
CONTROL_NODE_AUTORISE="non"  # préparer aussi cn-ansible (option --control-node)
SIMULATION="non"         # afficher les actions sans les exécuter (option --simulation)

DOSSIER_SCRIPT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DOSSIER_GABARITS="${DOSSIER_SCRIPT}/../templates"

# --- Fichiers temporaires ----------------------------------------------------
FICHIER_TEMPORAIRE=""

nettoyer() {
  if [ -n "$FICHIER_TEMPORAIRE" ]; then
    rm -f -- "$FICHIER_TEMPORAIRE"
  fi
}
trap nettoyer EXIT

# --- Fonctions de trace ------------------------------------------------------
log()    { printf '[INFO] %s\n' "$*"; }
succes() { printf '[OK] %s\n' "$*"; }
avert()  { printf '[AVERTISSEMENT] %s\n' "$*" >&2; }
erreur() { printf '[ERREUR] %s\n' "$*" >&2; exit 1; }

# Exécute une commande, ou l'affiche si le mode simulation'est actif.
executer() {
  if [ "$SIMULATION" = "oui" ]; then
    printf '    [simulation] %s\n' "$*"
    return 0
  fi
  "$@"
}

usage() {
  cat <<'AIDE'
Utilisation : 10-preparer-vm.sh --nom <machine> --ip <adresse> [options]

Prépare une VM du lab Ansible : nom d'hôte, adresse IP statique sur le réseau
privé 172.16.0.0/24, cloud-init, serveur SSH, Python, compte stagiaire et
résolution de noms. À exécuter avec les droits root, DANS la VM.

En situation de cours, ce script s'exécute sur le seul node web1, livré
vierge. Le control node cn-ansible est livré déjà équipé : le script le
refuse, sauf avec l'option --control-node (reconstruction intégrale du lab).

Options :
  --nom <machine>      Nom de la machine : web1 (cas normal) ou cn-ansible
                       (reconstruction intégrale, avec --control-node).
                       Obligatoire.
  --ip <adresse>       Adresse IPv4 statique sur le réseau privé. Obligatoire.
  --interface <nom>    Forcer l'interface du réseau privé. Sans cette option,
                       le script détecte l'interface automatiquement :
                         1. interface portant déjà une adresse 172.16.0.x ;
                         2. interface déclarée dans /etc/netplan/99-lab.yaml ;
                         3. deuxième interface physique (créée après la NAT) ;
                         4. unique interface physique disponible.
  --masque <longueur>  Longueur du préfixe du réseau privé. Valeur par défaut : 24.
  --gabarits <dossier> Dossier des gabarits. Valeur par défaut : labs/templates.
  --control-node       Autoriser la préparation du control node cn-ansible,
                       déjà livré équipé. Rapprochement idempotent uniquement :
                       aucun équipement existant (Ansible, clé SSH, projets)
                       n'est supprimé, et les fichiers déjà conformes restent
                       inchangés.
  --sans-paquets       Ne pas installer openssh-server ni python3.
  --simulation         Afficher les actions sans les exécuter.
  -h, --aide, --help   Afficher cette aide.

Adresses du lab (contrat d'adressage) :
  cn-ansible = 172.16.0.10 (control node)    web1 = 172.16.0.11 (node managé)

Exemple :
  sudo ./10-preparer-vm.sh --nom web1 --ip 172.16.0.11
AIDE
}

analyser_options() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--aide|--help) usage; exit 0 ;;
      --nom)          NOM="${2:?valeur manquante pour --nom}"; shift 2 ;;
      --nom=*)        NOM="${1#*=}"; shift ;;
      --ip)           ADRESSE_IP="${2:?valeur manquante pour --ip}"; shift 2 ;;
      --ip=*)         ADRESSE_IP="${1#*=}"; shift ;;
      --interface)    INTERFACE_FORCEE="${2:?valeur manquante pour --interface}"; shift 2 ;;
      --interface=*)  INTERFACE_FORCEE="${1#*=}"; shift ;;
      --masque)       MASQUE_LAB="${2:?valeur manquante pour --masque}"; shift 2 ;;
      --masque=*)     MASQUE_LAB="${1#*=}"; shift ;;
      --gabarits)     DOSSIER_GABARITS="${2:?chemin manquant pour --gabarits}"; shift 2 ;;
      --gabarits=*)   DOSSIER_GABARITS="${1#*=}"; shift ;;
      --control-node) CONTROL_NODE_AUTORISE="oui"; shift ;;
      --sans-paquets) INSTALLER_PAQUETS="non"; shift ;;
      --simulation)   SIMULATION="oui"; shift ;;
      "")             erreur "argument vide ; utiliser --aide pour la liste des options" ;;
      *)              erreur "option inconnue : $1 (utiliser --aide)" ;;
    esac
  done
}

# --- Vérifications préalables ------------------------------------------------
exiger_root() {
  [ "$(id -u)" -eq 0 ] || erreur "ce script doit être exécuté avec les droits root : sudo $0 $*"
}

verifier_parametres() {
  [ -n "$NOM" ] || erreur "l'option --nom est obligatoire (valeurs : ${NOMS_VM[*]})"
  [ -n "$ADRESSE_IP" ] || erreur "l'option --ip est obligatoire"

  local i position=0 valide="non"
  for i in "${!NOMS_VM[@]}"; do
    if [ "${NOMS_VM[$i]}" = "$NOM" ]; then
      position="$i"
      valide="oui"
    fi
  done
  [ "$valide" = "oui" ] || erreur "nom de machine inconnu : $NOM (valeurs : ${NOMS_VM[*]})"

  # Protection du control node livré équipé : il est refusé par défaut, afin
  # qu'une relance inopinée ne touche jamais à la machine déjà prête.
  if [ "$NOM" = "$NOM_CONTROL_NODE" ] && [ "$CONTROL_NODE_AUTORISE" = "non" ]; then
    erreur "$NOM_CONTROL_NODE est le control node livré déjà équipé : ce script s'exécute sur le seul node web1. Pour rapprocher un control node reconstruit de zéro, relancer avec --control-node (aucun équipement existant n'est supprimé)."
  fi
  if [ "$NOM" = "$NOM_CONTROL_NODE" ]; then
    log "control node $NOM_CONTROL_NODE : rapprochement idempotent autorisé (option --control-node)."
  fi

  local adresse_valide="non"
  if [[ "$ADRESSE_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    adresse_valide="oui"
  fi
  [ "$adresse_valide" = "oui" ] || erreur "adresse IPv4 invalide : $ADRESSE_IP"
  [[ "$ADRESSE_IP" == "$PREFIXE_RESEAU."* ]] \
    || avert "adresse $ADRESSE_IP hors du réseau privé du lab ($PREFIXE_RESEAU.0/$MASQUE_LAB)."

  if [ "$ADRESSE_IP" != "${IPS_VM[$position]}" ]; then
    avert "$NOM utilise normalement ${IPS_VM[$position]} dans le lab ; $ADRESSE_IP a été retenue."
  fi
}

verifier_prerequis() {
  command -v netplan >/dev/null 2>&1 \
    || erreur "netplan est introuvable : l'adressage statique du lab s'appuie sur netplan (Debian et Ubuntu). Sur une distribution pilotée par NetworkManager uniquement, appliquer l'adressage 172.16.0.x manuellement."
  [ -d /etc/netplan ] || mkdir -p /etc/netplan

  [ -f "$DOSSIER_GABARITS/99-lab.yaml" ] \
    || erreur "gabarit introuvable : $DOSSIER_GABARITS/99-lab.yaml (utiliser --gabarits pour indiquer le dossier labs/templates)."
  [ -f "$DOSSIER_GABARITS/00-subiquity-disable-cloudinit-networking.cfg" ] \
    || erreur "gabarit introuvable : $DOSSIER_GABARITS/00-subiquity-disable-cloudinit-networking.cfg"
  DOSSIER_GABARITS="$(cd -- "$DOSSIER_GABARITS" && pwd -P)"
  log "Gabarits : $DOSSIER_GABARITS"
}

# --- Écriture idempotente ----------------------------------------------------
# Écrit un fichier seulement si son contenu diffère : un second passage ne
# touche pas aux fichiers déjà conformes.
ecrire_si_different() {
  local cible="$1" contenu="$2" droits="$3"
  FICHIER_TEMPORAIRE="$(mktemp)"
  printf '%s\n' "$contenu" > "$FICHIER_TEMPORAIRE"
  if [ -f "$cible" ] && cmp -s "$FICHIER_TEMPORAIRE" "$cible"; then
    log "inchangé : $cible"
    return 0
  fi
  if [ "$SIMULATION" = "oui" ]; then
    printf '    [simulation] écriture de %s (droits %s), contenu :\n' "$cible" "$droits"
    sed 's/^/      | /' "$FICHIER_TEMPORAIRE"
    return 0
  fi
  install -D -m "$droits" "$FICHIER_TEMPORAIRE" "$cible"
  succes "écrit : $cible"
}

# --- Détection des interfaces réseau -----------------------------------------
# Liste les interfaces réseau matérielles : le lien /device est présent sur une
# carte réelle, absent sur lo et sur les interfaces virtuelles (docker, veth).
interfaces_physiques() {
  local chemin
  for chemin in /sys/class/net/*; do
    [ -e "$chemin/device" ] || continue
    printf '%s\n' "${chemin##*/}"
  done | sort -V
}

# Nom de l'interface déclarée sous ethernets: dans le fichier netplan du lab.
interface_dans_fichier_netplan() {
  [ -f "$CHEMIN_NETPLAN" ] || return 1
  awk '
    /^[[:space:]]*ethernets:[[:space:]]*$/ {dans = 1; next}
    dans && /^[^[:space:]]/ {dans = 0}
    dans && /^[[:space:]]+[A-Za-z0-9_-]+:[[:space:]]*$/ {
      nom = $1
      sub(":", "", nom)
      if (nom !~ /^_/) {print nom; exit}
    }
  ' "$CHEMIN_NETPLAN"
}

# Détermine l'interface reliée au réseau privé du lab.
detecter_interface_privee() {
  local -a physiques=()
  local candidat

  if [ -n "$INTERFACE_FORCEE" ]; then
    printf '%s\n' "$INTERFACE_FORCEE"
    return 0
  fi

  mapfile -t physiques < <(interfaces_physiques)
  if [ "${#physiques[@]}" -eq 0 ]; then
    return 1
  fi

  # 1. interface portant déjà une adresse du réseau privé
  for candidat in "${physiques[@]}"; do
    if ip -4 -o addr show dev "$candidat" 2>/dev/null | grep -q " $PREFIXE_RESEAU\."; then
      printf '%s\n' "$candidat"
      return 0
    fi
  done

  # 2. interface déjà déclarée dans le fichier netplan du lab
  candidat="$(interface_dans_fichier_netplan || true)"
  if [ -n "$candidat" ]; then
    printf '%s\n' "$candidat"
    return 0
  fi

  # 3. deuxième interface physique : 00-creer-vms.sh attache la NAT en premier
  #    et le réseau privé en second.
  if [ "${#physiques[@]}" -ge 2 ]; then
    printf '%s\n' "${physiques[1]}"
    return 0
  fi

  # 4. unique interface disponible : le lab en attend deux. La détection reste
  #    possible, mais la machine est hors de la topologie de référence.
  if [ "${#physiques[@]}" -eq 1 ]; then
    printf '[AVERTISSEMENT] une seule interface Ethernet détectée (%s) : vérifier les deux adaptateurs de la VM.\n' \
      "${physiques[0]}" >&2
    printf '%s\n' "${physiques[0]}"
    return 0
  fi

  return 1
}

# --- Étape 1 : nom d'hôte ----------------------------------------------------
configurer_nom_hote() {
  local actuel
  actuel="$(hostname)"
  if [ "$actuel" = "$NOM" ]; then
    log "nom d'hôte inchangé : $NOM"
    return 0
  fi
  log "nom d'hôte : $actuel devient $NOM"
  executer hostnamectl set-hostname "$NOM"
}

# --- Étape 2 : adressage statique du réseau privé ---------------------------
configurer_netplan() {
  local interface="$1"
  local gabarit rendu

  log "Lecture du gabarit $DOSSIER_GABARITS/99-lab.yaml."
  gabarit="$(cat "$DOSSIER_GABARITS/99-lab.yaml")"

  # Substitution des marqueurs du gabarit par substitution de chaînes : aucune
  # valeur n'est codée en dur dans le gabarit.
  rendu="${gabarit//__INTERFACE_LAB__/$interface}"
  rendu="${rendu//__ADRESSE_LAB__/$ADRESSE_IP}"
  rendu="${rendu//__MASQUE_LAB__/$MASQUE_LAB}"

  if [[ "$rendu" == *"__INTERFACE_LAB__"* || "$rendu" == *"__ADRESSE_LAB__"* || "$rendu" == *"__MASQUE_LAB__"* ]]; then
    erreur "gabarit netplan incomplet : un marqueur n'a pas été remplacé."
  fi

  log "Interface du réseau privé : $interface (adresse $ADRESSE_IP/$MASQUE_LAB)."
  ecrire_si_different "$CHEMIN_NETPLAN" "$rendu" "$DROITS_NETPLAN"
}

# Maintient un DHCP sur l'interface NAT si aucun fichier netplan de l
# installateur ne fournit déjà un accès Internet.
configurer_dhcp_nat() {
  if grep -rqs "dhcp4:[[:space:]]*true" /etc/netplan/ 2>/dev/null; then
    log "DHCP déjà géré par /etc/netplan : interface NAT conservée telle quelle."
    return 0
  fi
  local -a physiques=()
  local nat
  mapfile -t physiques < <(interfaces_physiques)
  if [ "${#physiques[@]}" -lt 2 ]; then
    avert "aucune configuration DHCP trouvée et une seule interface disponible :"
    avert "l'accès Internet de cette machine dépend de la configuration initiale."
    return 0
  fi
  nat="${physiques[0]}"
  log "Ajout d'une configuration DHCP sur l'interface NAT $nat."
  ecrire_si_different "$CHEMIN_NETPLAN_NAT" \
"# DHCP de l'interface NAT du lab, ajouté par 10-preparer-vm.sh.
# La route par défaut et l'accès Internet du lab passent par cette interface.
# Ne pas modifier : ce fichier est régénéré par le script de préparation.
network:
  version: 2
  renderer: networkd
  ethernets:
    $nat:
      dhcp4: true" "$DROITS_NETPLAN"
}

# --- Étape 3 : cloud-init ----------------------------------------------------
desactiver_reseau_cloud_init() {
  local gabarit
  gabarit="$(cat "$DOSSIER_GABARITS/00-subiquity-disable-cloudinit-networking.cfg")"
  ecrire_si_different "$CHEMIN_CLOUD_INIT" "$gabarit" "$DROITS_CLOUD_INIT"
}

# --- Étape 4 : paquets -------------------------------------------------------
installer_paquets() {
  if [ "$INSTALLER_PAQUETS" = "non" ]; then
    log "installation des paquets ignorée (option --sans-paquets)."
    return 0
  fi
  # Les paquets sont annoncés séparément pour permettre le contrôle de la
  # syntaxe ShellCheck sur chaque argument de apt-get.
  log "Installation de openssh-server et python3 (paquets requis par les nodes Ansible)."
  executer env DEBIAN_FRONTEND=noninteractive apt-get update
  executer env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    openssh-server python3
  succes "Paquets présents : openssh-server et python3."
}

# --- Étape 5 : compte stagiaire ----------------------------------------------
creer_utilisateur() {
  if id -u "$UTILISATEUR_LAB" >/dev/null 2>&1; then
    local uid_existant
    uid_existant="$(id -u "$UTILISATEUR_LAB")"
    if [ "$uid_existant" != "$UID_LAB" ]; then
      avert "compte $UTILISATEUR_LAB présent avec l'uid $uid_existant au lieu de $UID_LAB."
    else
      log "compte $UTILISATEUR_LAB déjà présent (uid $UID_LAB)."
    fi
  else
    log "Création du compte $UTILISATEUR_LAB (uid $UID_LAB)."
    executer useradd --uid "$UID_LAB" --create-home --shell "$COQUILLE" "$UTILISATEUR_LAB"
  fi

  if id -nG "$UTILISATEUR_LAB" 2>/dev/null | tr ' ' '\n' | grep -qx "$GROUPE_SUDO"; then
    log "groupe $GROUPE_SUDO déjà attribué à $UTILISATEUR_LAB."
  else
    log "Ajout de $UTILISATEUR_LAB au groupe $GROUPE_SUDO."
    executer usermod --append --groups "$GROUPE_SUDO" "$UTILISATEUR_LAB"
  fi

  ecrire_si_different "$CHEMIN_SUDOERS" \
"# Fichier généré par labs/scripts/10-preparer-vm.sh.
# Réservé au lab de formation isolé : ne pas reproduire sur une machine
# exposée, où un sudo sans mot de passe serait une faille.
$UTILISATEUR_LAB ALL=(ALL) NOPASSWD:ALL" "$DROITS_SUDOERS"

  if [ "$SIMULATION" = "non" ] && command -v visudo >/dev/null 2>&1; then
    if visudo --check --file="$CHEMIN_SUDOERS" >/dev/null 2>&1; then
      succes "règle sudo valide : $CHEMIN_SUDOERS"
    else
      erreur "règle sudo invalide : $CHEMIN_SUDOERS"
    fi
  fi
}

# --- Étape 6 : résolution de noms -------------------------------------------
maj_fichier_hosts() {
  local motif contenu bloc

  # Motif construit à partir du préfixe du réseau du lab, sans adresse en dur :
  # toute ligne déclarant une adresse du réseau 172.16.0.0/24 est gérée par le
  # script, y compris une entrée résiduelle d'un ancien lab à trois machines.
  motif="${PREFIXE_RESEAU//./\\.}\.[0-9]+"

  # Retrait du bloc précédent, puis des lignes du lab ajoutées à la main :
  # seules les lignes gérées par le script font foi.
  contenu="$(awk -v debut="$MARQUEUR_DEBUT" -v fin="$MARQUEUR_FIN" '
    index($0, debut) {bloc = 1; next}
    index($0, fin)   {bloc = 0; next}
    !bloc {print}
  ' "$FICHIER_HOSTS")"
  contenu="$(printf '%s\n' "$contenu" | grep -vE "^[^#]*(${motif})([[:space:]]|$)" || true)"

  # Les sauts de ligne de fin sont retirés pour reconstruire un fichier stable,
  # quel que soit le nombre d'exécutions successives du script.
  while [ -n "$contenu" ] && [ "${contenu: -1}" = $'\n' ]; do
    contenu="${contenu%$'\n'}"
  done

  printf -v bloc '%s\n%s\n%s\t%s\n%s\t%s\n%s' \
    "$MARQUEUR_DEBUT" \
    "# Entrées du lab Ansible, réseau privé $PREFIXE_RESEAU.0/$MASQUE_LAB." \
    "${IPS_VM[0]}" "${NOMS_VM[0]}" \
    "${IPS_VM[1]}" "${NOMS_VM[1]}" \
    "$MARQUEUR_FIN"

  if [ -n "$contenu" ]; then
    ecrire_si_different "$FICHIER_HOSTS" "${contenu}"$'\n\n'"${bloc}" "$DROITS_HOSTS"
  else
    ecrire_si_different "$FICHIER_HOSTS" "$bloc" "$DROITS_HOSTS"
  fi
}

# --- Étape 7 : serveur SSH ---------------------------------------------------
# Le service SSH ne porte pas le même nom selon la distribution : ssh sur
# Debian et Ubuntu, sshd sur Rocky et RHEL. L existence du fichier unité est
# vérifiée dans /lib et /usr/lib, ce qui ne dépend pas de systemd en cours.
nom_service_ssh() {
  local service
  for service in "$SERVICE_SSH_DEBIAN" "$SERVICE_SSH_RHEL"; do
    if [ -e "/lib/systemd/system/${service}.service" ] \
      || [ -e "/usr/lib/systemd/system/${service}.service" ]; then
      printf '%s\n' "$service"
      return 0
    fi
  done
  return 1
}

activer_serveur_ssh() {
  local service
  if service="$(nom_service_ssh)"; then
    log "Activation du service SSH ($service.service)."
  else
    service="$SERVICE_SSH_DEBIAN"
    avert "fichier unité $service.service introuvable : vérifier que le serveur SSH est installé, puis lancer manuellement : systemctl enable --now $service"
  fi
  executer systemctl enable --now "$service.service"
}

# --- Étape 8 : application du réseau ----------------------------------------
appliquer_netplan() {
  local interface="$1"
  local essai

  log "Validation puis application de la configuration réseau (netplan)."
  executer netplan generate
  executer netplan apply

  if [ "$SIMULATION" = "oui" ]; then
    log "contrôle simulé de la présence de $ADRESSE_IP/$MASQUE_LAB sur $interface."
    return 0
  fi

  essai=0
  while [ "$essai" -lt "$ATTENTE_ADRESSE" ]; do
    if ip -4 -o addr show dev "$interface" 2>/dev/null | grep -q " $ADRESSE_IP/$MASQUE_LAB"; then
      succes "Adresse $ADRESSE_IP/$MASQUE_LAB active sur $interface."
      return 0
    fi
    sleep 1
    essai=$((essai + 1))
  done
  avert "adresse $ADRESSE_IP/$MASQUE_LAB non visible sur $interface après ${ATTENTE_ADRESSE} s."
  ip -br -4 addr show dev "$interface" 2>/dev/null || true
  return 0
}

# --- Programme principal -----------------------------------------------------
afficher_recapitulatif() {
  local interface="$1"
  printf '\n== Récapitulatif de la préparation ==\n'
  printf 'Machine             : %s\n' "$NOM"
  printf 'Adresse de lab      : %s/%s\n' "$ADRESSE_IP" "$MASQUE_LAB"
  printf 'Interface privée    : %s\n' "$interface"
  printf 'Gabarits utilisés    : %s\n' "$DOSSIER_GABARITS"
  printf 'Compte créé         : %s (uid %s, sudo sans mot de passe)\n' "$UTILISATEUR_LAB" "$UID_LAB"
  printf 'Paquets             : %s\n' "$PAQUETS_LAB"
  printf '\nAvertissement : netplan apply coupe brièvement la connexion réseau.\n'
  printf 'Le faire depuis la console de la VM, puis contrôler le lab avec\n'
  printf 'labs/scripts/90-verifier-lab.sh.\n\n'
}

main() {
  analyser_options "$@"
  exiger_root "$@"
  verifier_parametres
  verifier_prerequis

  local interface
  interface="$(detecter_interface_privee)" \
    || erreur "aucune interface réseau physique détectée : vérifier les deux adaptateurs de la VM (NAT + réseau privé) ou indiquer l'interface attendue avec --interface enp0s8."
  log "Interface du réseau privé retenue : $interface"

  afficher_recapitulatif "$interface"

  if [ "$SIMULATION" = "oui" ]; then
    log "Mode simulation : aucune commande exécutée."
  fi

  configurer_nom_hote
  configurer_netplan "$interface"
  configurer_dhcp_nat
  desactiver_reseau_cloud_init
  installer_paquets
  creer_utilisateur
  maj_fichier_hosts
  activer_serveur_ssh
  appliquer_netplan "$interface"

  printf '\n'
  succes "Préparation de $NOM terminée."
  log "Contrôler depuis le poste avec labs/scripts/90-verifier-lab.sh."
}

main "$@"