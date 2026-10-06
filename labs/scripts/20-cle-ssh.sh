#!/usr/bin/env bash
# ===========================================================================
# 20-cle-ssh.sh — Déploiement de la clé SSH du control node vers les deux VM du lab
#
# Où l'exécuter : sur le CONTROL NODE (recommandé, option --reseau-prive) ou
# sur le POSTE HÔTE (ports NAT), une fois les VM démarrées et préparées par
# 10-preparer-vm.sh.
#
# Ce que fait le script :
#   1. vérifie la présence de ssh-keygen, ssh-copy-id et ssh ;
#   2. génère ~/.ssh/id_ed25519 si elle n'existe pas (jamais d'écrasement) ;
#   3. copie la clé publique vers cn-ansible et web1, via les ports de
#      redirection NAT du poste (2222, 2223) ou via le réseau privé ;
#   4. teste la connexion sans mot de passe sur chaque VM et compare le nom
#      d'hôte renvoyé au nom attendu ;
#   5. affiche un récapitulatif et renvoie un code de sortie non nul si une
#      machine reste inaccessible.
#
# Note : la clé est déjà présente sur le control node livré équipé ; sur
# cn-ansible, ssh-copy-id constate qu'elle y est déjà et ne demande aucun
# mot de passe. La saisie n'a lieu que pour web1, livré vierge.
#
# Sécurité : la clé privée reste sur la machine qui l'utilise et n'est jamais
# copiée ni affichée. Aucun mot de passe n'est stocké : ssh-copy-id demande le
# mot de passe du compte stagiaire, fourni par le formateur.
# ===========================================================================
set -euo pipefail

# --- Contrat d'adressage du lab ---------------------------------------------
readonly -a NOMS_VM=("cn-ansible" "web1")
readonly -a IPS_VM=("172.16.0.10" "172.16.0.11")
# Ports de redirection NAT configurés par 00-creer-vms.sh : le poste atteint
# chaque VM en 127.0.0.1 : le port 22 de la VM y est exposé par ces ports.
readonly -a PORTS_NAT=(2222 2223)
readonly HOTE_NAT="127.0.0.1"   # adresse utilisée côté poste pour la redirection NAT
readonly UTILISATEUR="stagiaire" # compte créé par 10-preparer-vm.sh sur chaque VM

# --- Paramètres de la clé ----------------------------------------------------
readonly TYPE_CLE="ed25519"        # type de clé recommandé, court et robuste
readonly COMMENTAIRE_CLE="lab-ansible"  # commentaire tracé dans la clé publique
readonly DELAI_CONNEXION=10        # secondes accordées à une connexion SSH
readonly DROITS_CLE="600"          # permissions de la clé privée
readonly DROITS_CLE_PUBLIQUE="644" # permissions de la clé publique

# --- Valeurs par défaut (modifiables par les options de la ligne de commande) -
CHEMIN_CLE="${HOME}/.ssh/id_ed25519"  # clé privée par défaut (option --identite)
MODE_ACCES="nat"      # nat : via les ports du poste ; prive : via 172.16.0.x
SIMULATION="non"      # afficher les commandes sans les exécuter
GENERER_CLE="oui"     # générer la clé si elle est absente (option --sans-generation)

ECHECS=0

# --- Fonctions de trace ------------------------------------------------------
log()     { printf '[INFO] %s\n' "$*"; }
succes()  { printf '[OK] %s\n' "$*"; }
erreur()  { printf '[ERREUR] %s\n' "$*" >&2; exit 1; }
echec()   { ECHECS=$((ECHECS + 1)); printf '[ECHEC] %s\n' "$*" >&2; }

executer() {
  if [ "$SIMULATION" = "oui" ]; then
    printf '    [simulation] %s\n' "$*"
    return 0
  fi
  "$@"
}

# Adresse et port à utiliser pour une machine, selon le mode d'accès choisi.
cible() {
  local index="$1"
  if [ "$MODE_ACCES" = "prive" ]; then
    printf '%s %s\n' "${IPS_VM[$index]}" "22"
  else
    printf '%s %s\n' "$HOTE_NAT" "${PORTS_NAT[$index]}"
  fi
}

usage() {
  cat <<'AIDE'
Utilisation : 20-cle-ssh.sh [options]

Déploie la clé SSH vers les deux machines du lab Ansible (cn-ansible et
web1), puis vérifie la connexion sans mot de passe. À exécuter sur le
control node, après la préparation de web1 par 10-preparer-vm.sh.

Options :
  --identite <fichier>  Chemin de la clé privée.
                        Valeur par défaut : ~/.ssh/id_ed25519
  --reseau-prive        Atteindre les machines par leur adresse du réseau privé
                        (172.16.0.10 et 172.16.0.11) au lieu des ports de
                        redirection NAT du poste (2222 et 2223).
                        À utiliser depuis une machine du réseau privé du lab,
                        en particulier depuis le control node.
  --sans-generation     Ne pas générer de clé si elle est absente.
  --simulation          Afficher les commandes sans les exécuter.
  -h, --aide, --help    Afficher cette aide.

Déroulement attendu :
  1. génération de la clé, uniquement si elle n'existe pas ;
  2. ssh-copy-id vers cn-ansible puis web1 : sur cn-ansible, la clé est déjà
     présente et aucune saisie n'a lieu ; sur web1, le mot de passe du compte
     stagiaire est demandé une fois (fourni par le formateur) ;
  3. test de connexion sans mot de passe et comparaison du nom d'hôte.

Code de sortie : 0 si les deux machines répondent, 1 sinon.
AIDE
}

analyser_options() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--aide|--help)   usage; exit 0 ;;
      --identite)         CHEMIN_CLE="${2:?chemin manquant pour --identite}"; shift 2 ;;
      --identite=*)       CHEMIN_CLE="${1#*=}"; shift ;;
      --reseau-prive)     MODE_ACCES="prive"; shift ;;
      --sans-generation)  GENERER_CLE="non"; shift ;;
      --simulation)       SIMULATION="oui"; shift ;;
      "")                 erreur "argument vide ; utiliser --aide pour la liste des options" ;;
      *)                  erreur "option inconnue : $1 (utiliser --aide)" ;;
    esac
  done
}

verifier_outils() {
  local outil
  for outil in ssh ssh-keygen ssh-copy-id; do
    command -v "$outil" >/dev/null 2>&1 \
      || erreur "outil introuvable : $outil (paquet openssh-client)"
  done
  log "Client SSH : $(ssh -V 2>&1)"
}

# --- Étape 1 : clé privée ----------------------------------------------------
generer_cle_si_absente() {
  if [ -f "$CHEMIN_CLE" ]; then
    if [ ! -f "$CHEMIN_CLE.pub" ]; then
      log "clé publique absente : reconstruction depuis la clé privée."
      if [ "$SIMULATION" = "oui" ]; then
        printf '    [simulation] ssh-keygen -y -f %s > %s.pub\n' "$CHEMIN_CLE" "$CHEMIN_CLE"
      else
        ssh-keygen -y -f "$CHEMIN_CLE" > "${CHEMIN_CLE}.pub"
        chmod "$DROITS_CLE_PUBLIQUE" "${CHEMIN_CLE}.pub"
      fi
    fi
    succes "clé existante : $CHEMIN_CLE (aucune génération, clé préservée)."
    return 0
  fi
  if [ "$GENERER_CLE" = "non" ]; then
    erreur "clé absente : $CHEMIN_CLE (option --sans-generation active)."
  fi
  log "génération de la clé $CHEMIN_CLE (type $TYPE_CLE, sans phrase de passe)."
  if [ "$SIMULATION" = "oui" ]; then
    printf '    [simulation] ssh-keygen -t %s -N "" -C %s -f %s\n' \
      "$TYPE_CLE" "$COMMENTAIRE_CLE" "$CHEMIN_CLE"
  else
    mkdir -p "$(dirname -- "$CHEMIN_CLE")"
    chmod 700 "$(dirname -- "$CHEMIN_CLE")"
    ssh-keygen -t "$TYPE_CLE" -N "" -C "$COMMENTAIRE_CLE" -f "$CHEMIN_CLE"
    chmod "$DROITS_CLE" "$CHEMIN_CLE"
    chmod "$DROITS_CLE_PUBLIQUE" "${CHEMIN_CLE}.pub"
    succes "clé générée : $CHEMIN_CLE"
  fi
}

# --- Étape 2 : copie de la clé publique --------------------------------------
copier_cle() {
  local index="$1" nom="${NOMS_VM[$1]}"
  local hote port
  read -r hote port <<< "$(cible "$index")"

  log "Copie de la clé publique vers $nom ($UTILISATEUR@$hote, port $port)."
  log "Mot de passe du compte $UTILISATEUR demandé si la clé n'est pas déjà présente sur $nom."
  if executer ssh-copy-id \
      -i "$CHEMIN_CLE.pub" \
      -p "$port" \
      -o "ConnectTimeout=$DELAI_CONNEXION" \
      -o StrictHostKeyChecking=accept-new \
      "$UTILISATEUR@$hote"; then
    succes "Clé publique installée sur $nom."
    return 0
  fi
  echec "copie de la clé impossible vers $nom ($hote port $port)."
  return 1
}

# --- Étape 3 : test de connexion ---------------------------------------------
tester_connexion() {
  local index="$1" nom="${NOMS_VM[$1]}"
  local hote port nom_obtenu
  read -r hote port <<< "$(cible "$index")"

  if [ "$SIMULATION" = "oui" ]; then
    printf '    [simulation] test de %s@%s port %s\n' "$UTILISATEUR" "$hote" "$port"
    return 0
  fi

  nom_obtenu="$(ssh \
      -i "$CHEMIN_CLE" \
      -p "$port" \
      -o BatchMode=yes \
      -o "ConnectTimeout=$DELAI_CONNEXION" \
      -o StrictHostKeyChecking=accept-new \
      "$UTILISATEUR@$hote" 'hostname -s' 2>/dev/null)" || {
    echec "connexion sans mot de passe impossible vers $nom ($hote port $port)."
    return 1
  }

  if [ "$nom_obtenu" = "$nom" ]; then
    succes "$nom répond sur $hote port $port (nom d'hôte : $nom_obtenu)."
    return 0
  fi
  echec "$nom a répondu $nom_obtenu : le nom d'hôte ne correspond pas."
  return 1
}

# --- Programme principal -----------------------------------------------------
main() {
  analyser_options "$@"
  verifier_outils

  generer_cle_si_absente
  [ -f "$CHEMIN_CLE.pub" ] || erreur "clé publique absente : $CHEMIN_CLE.pub (utiliser --identite pour désigner une autre clé)."

  printf '\n== Machines cibles ==\n'
  printf '%-12s %-14s %-6s %s\n' "machine" "adresse" "port" "mode"
  local i
  for i in "${!NOMS_VM[@]}"; do
    local hote port
    read -r hote port <<< "$(cible "$i")"
    printf '%-12s %-14s %-6s %s\n' "${NOMS_VM[$i]}" "$hote" "$port" "$MODE_ACCES"
  done
  printf '\n'

  for i in "${!NOMS_VM[@]}"; do
    copier_cle "$i" || true
  done

  printf '\n== Test de connexion sans mot de passe ==\n'
  for i in "${!NOMS_VM[@]}"; do
    tester_connexion "$i" || true
  done

  printf '\n== Récapitulatif ==\n'
  if [ "$ECHECS" -eq 0 ]; then
    succes "Les deux machines du lab sont accessibles en SSH sans mot de passe."
    exit 0
  fi
  echec "$ECHECS vérification(s) en échec."
  exit 1
}

main "$@"